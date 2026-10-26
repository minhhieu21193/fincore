package payments

import (
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"strconv"

	"github.com/google/uuid"

	"github.com/minhhieu21193/fincore/internal/platform/httpx"
)

// Handler exposes the payments API.
type Handler struct {
	svc       *Service
	faultRate float64
}

// NewHandler returns the API handler. faultRate > 0 only in the deliberately
// bad build; see buildinfo.FaultRate.
func NewHandler(svc *Service, faultRate float64) *Handler {
	return &Handler{svc: svc, faultRate: faultRate}
}

// Register mounts the routes on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/payments", h.create)
	mux.HandleFunc("GET /v1/payments/{id}", h.get)
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	if h.faultRate > 0 && rand.Float64() < h.faultRate { //nolint:gosec // fault injection, not security relevant
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "injected fault (bad build)")
		return
	}
	key := r.Header.Get("Idempotency-Key")
	if key == "" || len(key) > 255 {
		httpx.WriteError(w, http.StatusBadRequest, "idempotency_key_required", "send a unique Idempotency-Key header (1-255 chars) with every POST")
		return
	}
	var req CreateRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusUnprocessableEntity, "invalid_request", err.Error())
		return
	}

	res, err := h.svc.Create(r.Context(), key, req)
	switch {
	case errors.Is(err, ErrKeyReuse):
		httpx.WriteError(w, http.StatusUnprocessableEntity, "idempotency_key_reused", err.Error())
		return
	case errors.Is(err, ErrInFlight):
		w.Header().Set("Retry-After", "1")
		httpx.WriteError(w, http.StatusConflict, "request_in_progress", err.Error())
		return
	case errors.Is(err, ErrProcessorUnavailable):
		w.Header().Set("Retry-After", "2")
		httpx.WriteError(w, http.StatusServiceUnavailable, "processor_unavailable", "retry with the same Idempotency-Key")
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "create payment", "error", err)
		w.Header().Set("Retry-After", "2")
		httpx.WriteError(w, http.StatusServiceUnavailable, "temporarily_unavailable", "retry with the same Idempotency-Key")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Idempotent-Replayed", strconv.FormatBool(res.Replayed))
	w.WriteHeader(res.Status)
	_, _ = w.Write(res.Body)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "id must be a UUID")
		return
	}
	p, err := h.svc.Get(r.Context(), id)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "get payment", "error", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, p)
}
