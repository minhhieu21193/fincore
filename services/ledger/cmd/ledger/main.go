// Command ledger serves the double-entry ledger API.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/minhhieu21193/fincore/internal/platform/config"
	"github.com/minhhieu21193/fincore/internal/platform/httpx"
	"github.com/minhhieu21193/fincore/internal/platform/logging"
	"github.com/minhhieu21193/fincore/internal/platform/pg"
	"github.com/minhhieu21193/fincore/internal/platform/telemetry"
	"github.com/minhhieu21193/fincore/services/ledger/internal/ledger"
)

const service = "ledger"

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

	drain, err := config.Duration("SHUTDOWN_DRAIN_DELAY", 5*time.Second)
	if err != nil {
		return err
	}

	pool, err := pg.Connect(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := ledger.Migrate(ctx, pool); err != nil {
		return err
	}

	store := ledger.NewStore(pool)
	go ledger.WatchInvariants(ctx, store, 15*time.Second)

	mux := http.NewServeMux()
	ledger.NewHandler(store).Register(mux)
	rd := httpx.NewReadiness(pool.Ping)
	rd.Register(mux)

	return httpx.Run(ctx, httpx.Config{
		Addr:        config.String("HTTP_ADDR", ":8080"),
		MetricsAddr: config.String("METRICS_ADDR", ":9090"),
		DrainDelay:  drain,
	}, httpx.Instrument(service, mux), rd)
}
