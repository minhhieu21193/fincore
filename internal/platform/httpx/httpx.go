// Package httpx contains the HTTP plumbing shared by every FinCore service:
// RED metrics, access logs, tracing, panic recovery, health probes, JSON
// helpers and a server runner with graceful shutdown.
package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/minhhieu21193/fincore/internal/platform/buildinfo"
)

// Registry is the Prometheus registry every service registers into. It is
// separate from the global default so tests do not share state.
var Registry = prometheus.NewRegistry()

var (
	requests = promauto.With(Registry).NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests handled, by route pattern, method and status code.",
	}, []string{"route", "method", "code"})
	duration = promauto.With(Registry).NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency, by route pattern and method.",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.75, 1, 2.5, 5},
	}, []string{"route", "method"})
	inflight = promauto.With(Registry).NewGauge(prometheus.GaugeOpts{
		Name: "http_requests_in_flight",
		Help: "HTTP requests currently being served.",
	})
)

func init() {
	Registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	promauto.With(Registry).NewGaugeFunc(prometheus.GaugeOpts{
		Name:        "fincore_build_info",
		Help:        "Build metadata; always 1.",
		ConstLabels: prometheus.Labels{"version": buildinfo.Version, "commit": buildinfo.Commit},
	}, func() float64 { return 1 })
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Instrument wraps the API handler with tracing, metrics, access logging and
// panic recovery. Metrics are labelled with the matched route pattern (never
// the raw path) to keep cardinality bounded.
func Instrument(service string, mux *http.ServeMux) http.Handler {
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		inflight.Inc()
		defer func() {
			inflight.Dec()
			if p := recover(); p != nil {
				slog.ErrorContext(r.Context(), "panic serving request", "panic", p, "path", r.URL.Path)
				rec.status = http.StatusInternalServerError
				http.Error(rec, `{"error":"internal_error"}`, http.StatusInternalServerError)
			}
			_, route := mux.Handler(r)
			if route == "" {
				route = "unmatched"
			}
			elapsed := time.Since(start)
			requests.WithLabelValues(route, r.Method, strconv.Itoa(rec.status)).Inc()
			duration.WithLabelValues(route, r.Method).Observe(elapsed.Seconds())
			if r.URL.Path != "/healthz" && r.URL.Path != "/readyz" {
				slog.InfoContext(r.Context(), "request",
					"method", r.Method, "route", route, "status", rec.status,
					"duration_ms", elapsed.Milliseconds())
			}
		}()
		mux.ServeHTTP(rec, r)
	})
	return otelhttp.NewHandler(h, service, otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
		return r.Method + " " + r.URL.Path
	}))
}

// Readiness reports whether the instance should receive traffic. It turns
// false as soon as shutdown begins so the endpoint is removed from Services
// before connections are drained.
type Readiness struct {
	shuttingDown atomic.Bool
	check        func(context.Context) error
}

// NewReadiness creates a probe; check may be nil.
func NewReadiness(check func(context.Context) error) *Readiness {
	return &Readiness{check: check}
}

// Register mounts /healthz (liveness) and /readyz (readiness) on mux.
func (rd *Readiness) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if rd.shuttingDown.Load() {
			WriteJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting_down"})
			return
		}
		if rd.check != nil {
			ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
			defer cancel()
			if err := rd.check(ctx); err != nil {
				WriteJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "not_ready", "error": err.Error()})
				return
			}
		}
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	})
}

// WriteJSON writes v as a JSON response.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("encode response", "error", err)
	}
}

// Error is the uniform error body returned by every API.
type Error struct {
	Code    string `json:"error"`
	Message string `json:"message,omitempty"`
}

// WriteError writes an Error body.
func WriteError(w http.ResponseWriter, status int, code, msg string) {
	WriteJSON(w, status, Error{Code: code, Message: msg})
}

// DecodeJSON decodes a size-limited JSON body, rejecting unknown fields.
func DecodeJSON(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// Config controls Run.
type Config struct {
	Addr        string        // API listener, e.g. ":8080"
	MetricsAddr string        // metrics listener, e.g. ":9090"
	DrainDelay  time.Duration // time between failing readiness and closing listeners
}

// Run serves handler on cfg.Addr and /metrics on cfg.MetricsAddr until ctx is
// cancelled, then shuts down gracefully: readiness fails first, then after
// DrainDelay the servers stop accepting and in-flight requests finish.
func Run(ctx context.Context, cfg Config, handler http.Handler, rd *Readiness) error {
	api := &http.Server{
		Addr:              cfg.Addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       90 * time.Second,
		BaseContext:       func(net.Listener) context.Context { return context.WithoutCancel(ctx) },
	}
	mm := http.NewServeMux()
	mm.Handle("GET /metrics", promhttp.HandlerFor(Registry, promhttp.HandlerOpts{}))
	metrics := &http.Server{Addr: cfg.MetricsAddr, Handler: mm, ReadHeaderTimeout: 5 * time.Second}

	errCh := make(chan error, 2)
	for _, s := range []*http.Server{api, metrics} {
		go func() {
			slog.Info("listening", "addr", s.Addr)
			if err := s.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				errCh <- err
			}
		}()
	}

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}
	slog.Info("shutdown started", "drain_delay", cfg.DrainDelay.String())
	if rd != nil {
		rd.shuttingDown.Store(true)
	}
	time.Sleep(cfg.DrainDelay)
	sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	err := api.Shutdown(sctx)
	_ = metrics.Shutdown(sctx)
	return err
}

// ConnRecycleInterval is how often a Client drops its idle keep-alive
// connections (see Client).
const ConnRecycleInterval = 10 * time.Second

// Client returns an HTTP client for calls to other services. It propagates
// trace context and keeps connections alive, but drops idle connections every
// ConnRecycleInterval. Kubernetes Services balance per connection, so a
// keep-alive pool that is never recycled stays pinned to the pods that existed
// when it was opened: a canary, a scaled-out replica or a replacement pod
// would receive no traffic from this client.
func Client(timeout time.Duration) *http.Client {
	base := http.DefaultTransport.(*http.Transport).Clone()
	return &http.Client{Timeout: timeout, Transport: otelhttp.NewTransport(newRecyclingTransport(base, ConnRecycleInterval))}
}

// recyclingTransport closes the idle connections of its pool at most once per
// interval, from RoundTrip itself (no background goroutine). Connections that
// are in use finish their request and are closed at the next recycle.
type recyclingTransport struct {
	base     *http.Transport
	interval time.Duration
	next     atomic.Int64 // UnixNano of the next recycle
}

func newRecyclingTransport(base *http.Transport, interval time.Duration) *recyclingTransport {
	t := &recyclingTransport{base: base, interval: interval}
	t.next.Store(time.Now().Add(interval).UnixNano())
	return t
}

func (t *recyclingTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	now := time.Now().UnixNano()
	if n := t.next.Load(); now >= n && t.next.CompareAndSwap(n, now+int64(t.interval)) {
		t.base.CloseIdleConnections()
	}
	return t.base.RoundTrip(r)
}

// CloseIdleConnections lets http.Client.CloseIdleConnections reach the pool.
func (t *recyclingTransport) CloseIdleConnections() { t.base.CloseIdleConnections() }
