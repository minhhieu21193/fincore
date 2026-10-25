// Command payments-api accepts card payments.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/minhhieu21193/fincore/internal/platform/buildinfo"
	"github.com/minhhieu21193/fincore/internal/platform/config"
	"github.com/minhhieu21193/fincore/internal/platform/httpx"
	"github.com/minhhieu21193/fincore/internal/platform/logging"
	"github.com/minhhieu21193/fincore/internal/platform/pg"
	"github.com/minhhieu21193/fincore/internal/platform/queue"
	"github.com/minhhieu21193/fincore/internal/platform/telemetry"
	"github.com/minhhieu21193/fincore/services/payments-api/internal/payments"
)

const service = "payments-api"

func main() {
	logging.New(service)
	if err := run(); err != nil {
		slog.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	shutdownTracing, err := telemetry.Setup(ctx, service)
	if err != nil {
		return err
	}
	defer func() { _ = shutdownTracing(context.Background()) }()

	ledgerURL, err := config.Required("LEDGER_URL")
	if err != nil {
		return err
	}
	queueURL, err := config.Required("SQS_QUEUE_URL")
	if err != nil {
		return err
	}
	latency, err := config.Duration("PROCESSOR_LATENCY", 40*time.Millisecond)
	if err != nil {
		return err
	}
	jitter, err := config.Duration("PROCESSOR_JITTER", 30*time.Millisecond)
	if err != nil {
		return err
	}
	declineRate, err := config.Float("PROCESSOR_DECLINE_RATE", 0.02)
	if err != nil {
		return err
	}
	feeBps, err := config.Int("FEE_BPS", 290)
	if err != nil {
		return err
	}
	lockTTL, err := config.Duration("IDEMPOTENCY_LOCK_TTL", 30*time.Second)
	if err != nil {
		return err
	}
	drain, err := config.Duration("SHUTDOWN_DRAIN_DELAY", 5*time.Second)
	if err != nil {
		return err
	}
	faultRate, err := strconv.ParseFloat(buildinfo.FaultRate, 64)
	if err != nil {
		return err
	}
	if faultRate > 0 {
		slog.Warn("THIS IS A DELIBERATELY BAD BUILD: injecting HTTP 500s", "fault_rate", faultRate)
	}

	pool, err := pg.Connect(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := payments.Migrate(ctx, pool); err != nil {
		return err
	}
	sqsClient, err := queue.NewSQS(ctx)
	if err != nil {
		return err
	}

	store := payments.NewStore(pool, lockTTL)
	svc := payments.NewService(store,
		payments.NewFakeProcessor(latency, jitter, declineRate),
		payments.NewLedgerClient(ledgerURL, int64(feeBps)))

	relayCtx, stopRelay := context.WithCancel(context.WithoutCancel(ctx))
	relayDone := make(chan struct{})
	go func() {
		defer close(relayDone)
		payments.RunRelay(relayCtx, store, &payments.SQSPublisher{Client: sqsClient, QueueURL: queueURL}, 500*time.Millisecond)
	}()

	mux := http.NewServeMux()
	payments.NewHandler(svc, faultRate).Register(mux)
	rd := httpx.NewReadiness(pool.Ping)
	rd.Register(mux)

	err = httpx.Run(ctx, httpx.Config{
		Addr:        config.String("HTTP_ADDR", ":8080"),
		MetricsAddr: config.String("METRICS_ADDR", ":9090"),
		DrainDelay:  drain,
	}, httpx.Instrument(service, mux), rd)

	// Unpublished rows stay in the outbox and are relayed by another replica
	// (or by this one after restart); nothing is lost.
	stopRelay()
	<-relayDone
	return err
}
