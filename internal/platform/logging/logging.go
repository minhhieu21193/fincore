// Package logging configures structured JSON logs that carry the active trace ID.
package logging

import (
	"context"
	"log/slog"
	"os"
	"strings"

	"go.opentelemetry.io/otel/trace"

	"github.com/minhhieu21193/fincore/internal/platform/buildinfo"
)

// New returns a JSON logger tagged with the service name and build version and
// installs it as the slog default.
func New(service string) *slog.Logger {
	level := slog.LevelInfo
	switch strings.ToLower(os.Getenv("LOG_LEVEL")) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	l := slog.New(traceHandler{h}).With(
		slog.String("service", service),
		slog.String("version", buildinfo.Version),
	)
	slog.SetDefault(l)
	return l
}

// traceHandler adds trace_id/span_id to every record logged with a context
// that carries a recording span, so logs and traces can be correlated.
type traceHandler struct{ slog.Handler }

func (h traceHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(slog.String("trace_id", sc.TraceID().String()), slog.String("span_id", sc.SpanID().String()))
	}
	return h.Handler.Handle(ctx, r)
}

func (h traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return traceHandler{h.Handler.WithAttrs(attrs)}
}

func (h traceHandler) WithGroup(name string) slog.Handler {
	return traceHandler{h.Handler.WithGroup(name)}
}
