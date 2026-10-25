// Command notifier delivers payment events from SQS to merchant webhooks.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/minhhieu21193/fincore/internal/platform/config"
	"github.com/minhhieu21193/fincore/internal/platform/httpx"
	"github.com/minhhieu21193/fincore/internal/platform/logging"
	"github.com/minhhieu21193/fincore/internal/platform/queue"
	"github.com/minhhieu21193/fincore/internal/platform/telemetry"
	"github.com/minhhieu21193/fincore/services/notifier/internal/notifier"
)

const service = "notifier"

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

	queueURL, err := config.Required("SQS_QUEUE_URL")
	if err != nil {
		return err
	}
	secret, err := readSecret("WEBHOOK_SIGNING_SECRET")
	if err != nil {
		return err
	}
	dir, err := loadDirectory()
	if err != nil {
		return err
	}
	attempts, err := config.Int("DELIVERY_ATTEMPTS", 3)
	if err != nil {
		return err
	}
	concurrency, err := config.Int("CONCURRENCY", 8)
	if err != nil {
		return err
	}
	drain, err := config.Duration("SHUTDOWN_DRAIN_DELAY", 2*time.Second)
	if err != nil {
		return err
	}
	sqsClient, err := queue.NewSQS(ctx)
	if err != nil {
		return err
	}

	c := &notifier.Consumer{
		SQS:       sqsClient,
		QueueURL:  queueURL,
		Directory: dir,
		Sender: &notifier.Sender{
			HTTP: httpx.Client(5 * time.Second), Secret: secret,
			Attempts: attempts, Backoff: 200 * time.Millisecond, Now: time.Now,
		},
		Concurrency:   concurrency,
		MaxVisibility: 5 * time.Minute,
	}
	done := make(chan struct{})
	go func() { defer close(done); c.Run(ctx) }()

	mux := http.NewServeMux()
	rd := httpx.NewReadiness(nil)
	rd.Register(mux)
	err = httpx.Run(ctx, httpx.Config{
		Addr:        config.String("HTTP_ADDR", ":8080"),
		MetricsAddr: config.String("METRICS_ADDR", ":9090"),
		DrainDelay:  drain,
	}, httpx.Instrument(service, mux), rd)
	<-done
	return err
}

// readSecret reads NAME or the file at NAME_FILE.
func readSecret(name string) ([]byte, error) {
	if v := os.Getenv(name); v != "" {
		return []byte(v), nil
	}
	if f := os.Getenv(name + "_FILE"); f != "" {
		b, err := os.ReadFile(f) //nolint:gosec // path from trusted deployment config
		return []byte(strings.TrimSpace(string(b))), err
	}
	return nil, errors.New(name + " or " + name + "_FILE is required")
}

// loadDirectory reads merchant endpoints from MERCHANT_WEBHOOKS (JSON object
// merchant_id -> URL) plus DEFAULT_WEBHOOK_URL.
func loadDirectory() (notifier.Directory, error) {
	d := notifier.Directory{Endpoints: map[string]string{}, Default: os.Getenv("DEFAULT_WEBHOOK_URL")}
	if raw := os.Getenv("MERCHANT_WEBHOOKS"); raw != "" {
		if err := json.Unmarshal([]byte(raw), &d.Endpoints); err != nil {
			return d, errors.New("MERCHANT_WEBHOOKS must be a JSON object of merchant_id to URL")
		}
	}
	return d, nil
}
