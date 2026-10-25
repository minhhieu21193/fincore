// Command webhook-sink is a demo merchant endpoint. It verifies webhook
// signatures, deduplicates on event ID (delivery is at-least-once) and keeps
// what it received in memory so end-to-end tests can assert on it.
package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	"github.com/minhhieu21193/fincore/internal/platform/config"
	"github.com/minhhieu21193/fincore/internal/platform/httpx"
	"github.com/minhhieu21193/fincore/internal/platform/logging"
	"github.com/minhhieu21193/fincore/services/notifier/internal/signature"
)

const service = "webhook-sink"

var receivedTotal = promauto.With(httpx.Registry).NewCounterVec(prometheus.CounterOpts{
	Name: "webhook_sink_received_total",
	Help: "Webhooks received by the demo merchant endpoint, by result.",
}, []string{"result"})

type record struct {
	EventID    string          `json:"event_id"`
	EventType  string          `json:"event_type"`
	PaymentID  string          `json:"payment_id"`
	ReceivedAt time.Time       `json:"received_at"`
	Body       json.RawMessage `json:"body"`
}

type sink struct {
	secret []byte
	mu     sync.Mutex
	byID   map[string]record
	order  []string
}

func main() {
	logging.New(service)
	secret := os.Getenv("WEBHOOK_SIGNING_SECRET")
	if f := os.Getenv("WEBHOOK_SIGNING_SECRET_FILE"); secret == "" && f != "" {
		b, err := os.ReadFile(f) //nolint:gosec // path from trusted deployment config
		if err != nil {
			slog.Error("read secret", "error", err)
			os.Exit(1)
		}
		secret = strings.TrimSpace(string(b))
	}
	if secret == "" {
		slog.Error("WEBHOOK_SIGNING_SECRET is required")
		os.Exit(1)
	}
	s := &sink{secret: []byte(secret), byID: map[string]record{}}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /webhooks", s.receive)
	mux.HandleFunc("GET /received", s.list)
	rd := httpx.NewReadiness(nil)
	rd.Register(mux)
	if err := httpx.Run(ctx, httpx.Config{
		Addr:        config.String("HTTP_ADDR", ":8080"),
		MetricsAddr: config.String("METRICS_ADDR", ":9090"),
		DrainDelay:  time.Second,
	}, httpx.Instrument(service, mux), rd); err != nil {
		slog.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func (s *sink) receive(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := signature.Verify(s.secret, body, r.Header.Get(signature.Header), time.Now(), 5*time.Minute); err != nil {
		receivedTotal.WithLabelValues("bad_signature").Inc()
		httpx.WriteError(w, http.StatusUnauthorized, "bad_signature", err.Error())
		return
	}
	var ev struct {
		Payment struct {
			ID string `json:"id"`
		} `json:"payment"`
	}
	_ = json.Unmarshal(body, &ev)
	id := r.Header.Get("FinCore-Event-Id")

	s.mu.Lock()
	defer s.mu.Unlock()
	if _, dup := s.byID[id]; dup {
		receivedTotal.WithLabelValues("duplicate").Inc()
		w.WriteHeader(http.StatusOK)
		return
	}
	s.byID[id] = record{
		EventID: id, EventType: r.Header.Get("FinCore-Event-Type"), PaymentID: ev.Payment.ID,
		ReceivedAt: time.Now().UTC(), Body: body,
	}
	s.order = append(s.order, id)
	if len(s.order) > 10_000 { // bounded memory
		delete(s.byID, s.order[0])
		s.order = s.order[1:]
	}
	receivedTotal.WithLabelValues("accepted").Inc()
	w.WriteHeader(http.StatusNoContent)
}

func (s *sink) list(w http.ResponseWriter, r *http.Request) {
	pid := r.URL.Query().Get("payment_id")
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []record{}
	for _, id := range s.order {
		if rec := s.byID[id]; pid == "" || rec.PaymentID == pid {
			out = append(out, rec)
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"count": len(out), "events": out})
}
