package ledger

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	"github.com/minhhieu21193/fincore/internal/platform/httpx"
)

var (
	postedTotal = promauto.With(httpx.Registry).NewCounterVec(prometheus.CounterOpts{
		Name: "ledger_transactions_posted_total",
		Help: "Ledger transactions by outcome (created, replayed, rejected, conflict).",
	}, []string{"outcome"})
	imbalance = promauto.With(httpx.Registry).NewGaugeVec(prometheus.GaugeOpts{
		Name: "ledger_imbalance_minor_units",
		Help: "sum(debits) - sum(credits) across the whole ledger, per currency. Must always be 0.",
	}, []string{"currency"})
)

// Handler exposes the ledger API.
type Handler struct {
	store *Store
}

// NewHandler returns the API handler.
func NewHandler(store *Store) *Handler { return &Handler{store: store} }

// Register mounts the routes on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/transactions", h.post)
	mux.HandleFunc("GET /v1/transactions/{external_ref}", h.get)
	mux.HandleFunc("GET /v1/accounts/{code}/balance", h.balance)
	mux.HandleFunc("GET /v1/invariants", h.invariants)
}

func (h *Handler) post(w http.ResponseWriter, r *http.Request) {
	var in TransactionInput
	if err := httpx.DecodeJSON(w, r, &in); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	t, created, err := h.store.Post(r.Context(), in)
	switch {
	case errors.Is(err, ErrInvalid), errors.Is(err, ErrCurrencyClash):
		postedTotal.WithLabelValues("rejected").Inc()
		httpx.WriteError(w, http.StatusUnprocessableEntity, "invalid_transaction", err.Error())
	case errors.Is(err, ErrConflict):
		postedTotal.WithLabelValues("conflict").Inc()
		httpx.WriteError(w, http.StatusConflict, "external_ref_conflict", err.Error())
	case err != nil:
		slog.ErrorContext(r.Context(), "post transaction", "error", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "")
	case created:
		postedTotal.WithLabelValues("created").Inc()
		httpx.WriteJSON(w, http.StatusCreated, t)
	default:
		postedTotal.WithLabelValues("replayed").Inc()
		httpx.WriteJSON(w, http.StatusOK, t)
	}
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	t, err := h.store.GetByExternalRef(r.Context(), r.PathValue("external_ref"))
	if errors.Is(err, ErrNotFound) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "get transaction", "error", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, t)
}

func (h *Handler) balance(w http.ResponseWriter, r *http.Request) {
	b, err := h.store.Balance(r.Context(), r.PathValue("code"))
	if errors.Is(err, ErrNotFound) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "balance", "error", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, b)
}

func (h *Handler) invariants(w http.ResponseWriter, r *http.Request) {
	m, err := h.store.Imbalance(r.Context())
	if err != nil {
		slog.ErrorContext(r.Context(), "imbalance", "error", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "")
		return
	}
	balanced := true
	for _, v := range m {
		if v != 0 {
			balanced = false
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"balanced": balanced, "imbalance_by_currency": m})
}

// WatchInvariants refreshes the imbalance gauge until ctx is cancelled. The
// check reads every entry, so it runs once per interval across all replicas
// (Store.ClaimCheck): each instance asks every few seconds, one of them runs
// it. Each committed transaction is already balanced by database constraints;
// this is the independent, ledger-wide check on top.
func WatchInvariants(ctx context.Context, store *Store, every time.Duration) {
	t := time.NewTicker(every / 4)
	defer t.Stop()
	for {
		run, err := store.ClaimCheck(ctx, "imbalance", every)
		var m map[string]int64
		if err == nil && run {
			m, err = store.Imbalance(ctx)
		}
		switch {
		case err != nil:
			if ctx.Err() == nil {
				slog.Warn("refresh imbalance gauge", "error", err)
			}
		case run:
			for ccy, v := range m {
				imbalance.WithLabelValues(ccy).Set(float64(v))
				if v != 0 {
					slog.Error("LEDGER IMBALANCE DETECTED", "currency", ccy, "imbalance", v)
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
