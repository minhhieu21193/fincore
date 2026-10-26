package payments

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"

	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"

	"github.com/minhhieu21193/fincore/internal/platform/httpx"
)

// Event types written to the outbox.
const (
	EventCaptured = "payment.captured"
	EventFailed   = "payment.failed"
)

var (
	paymentsTotal = promauto.With(httpx.Registry).NewCounterVec(prometheus.CounterOpts{
		Name: "payments_total",
		Help: "Payments that reached a terminal state, by status.",
	}, []string{"status"})
	paymentAmount = promauto.With(httpx.Registry).NewCounterVec(prometheus.CounterOpts{
		Name: "payments_amount_minor_units_total",
		Help: "Captured payment volume in minor units, by currency.",
	}, []string{"currency"})
	idempotentReplays = promauto.With(httpx.Registry).NewCounter(prometheus.CounterOpts{
		Name: "payments_idempotent_replays_total",
		Help: "Requests answered from a stored idempotent response.",
	})

	tracer          = otel.Tracer("github.com/minhhieu21193/fincore/services/payments-api")
	merchantIDRegex = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	currencyRegex   = regexp.MustCompile(`^[A-Z]{3}$`)
)

// CreateRequest is the body of POST /v1/payments.
type CreateRequest struct {
	MerchantID string `json:"merchant_id"`
	Amount     int64  `json:"amount"`
	Currency   string `json:"currency"`
	CardToken  string `json:"card_token"`
}

// Validate checks the request shape.
func (r CreateRequest) Validate() error {
	switch {
	case !merchantIDRegex.MatchString(r.MerchantID):
		return errors.New("merchant_id must be 1-64 characters [A-Za-z0-9_-]")
	case r.Amount <= 0 || r.Amount > 100_000_000:
		return errors.New("amount must be between 1 and 100000000 minor units")
	case !currencyRegex.MatchString(r.Currency):
		return errors.New("currency must be an ISO-4217 code")
	case r.CardToken == "" || len(r.CardToken) > 64:
		return errors.New("card_token is required")
	}
	return nil
}

// Hash fingerprints the request for idempotency-key reuse detection. The
// card token is part of the fingerprint but is never stored in clear.
func (r CreateRequest) Hash() []byte {
	b, _ := json.Marshal(r) //nolint:errchkjson // plain struct, cannot fail
	sum := sha256.Sum256(b)
	return sum[:]
}

// Result is what the HTTP layer sends back.
type Result struct {
	Status   int
	Body     []byte
	Replayed bool
}

// Service orchestrates payment processing.
type Service struct {
	store     *Store
	processor Processor
	ledger    Ledger
}

// NewService wires the dependencies.
func NewService(store *Store, processor Processor, ledger Ledger) *Service {
	return &Service{store: store, processor: processor, ledger: ledger}
}

// Create processes a payment exactly once per (merchant, idempotency key).
func (s *Service) Create(ctx context.Context, key string, req CreateRequest) (Result, error) {
	ctx, span := tracer.Start(ctx, "payments.Create")
	defer span.End()
	span.SetAttributes(attribute.String("merchant.id", req.MerchantID))

	claim, err := s.store.Claim(ctx, Payment{
		ID: uuid.New(), MerchantID: req.MerchantID, Amount: req.Amount, Currency: req.Currency,
	}, key, req.Hash())
	if err != nil {
		return Result{}, err
	}
	if claim.Replay != nil {
		idempotentReplays.Inc()
		return Result{Status: claim.Replay.Status, Body: claim.Replay.Body, Replayed: true}, nil
	}
	if claim.Resumed {
		slog.InfoContext(ctx, "resuming payment from stale idempotency lock", "payment_id", claim.Payment.ID, "status", claim.Payment.Status)
	}
	span.SetAttributes(attribute.String("payment.id", claim.Payment.ID.String()))

	p, err := s.drive(ctx, claim.Payment, req.CardToken)
	if err != nil {
		// Technical failure: keep the payment in its current state and let a
		// retry with the same key resume from there.
		if rerr := s.store.ReleaseLock(context.WithoutCancel(ctx), req.MerchantID, key); rerr != nil {
			slog.ErrorContext(ctx, "release idempotency lock", "error", rerr)
		}
		return Result{}, err
	}

	status := http.StatusCreated
	if p.Status == StatusFailed {
		status = http.StatusPaymentRequired
	}
	body, err := json.Marshal(p)
	if err != nil {
		return Result{}, err
	}
	if err := s.store.SaveResponse(context.WithoutCancel(ctx), req.MerchantID, key, status, body); err != nil {
		return Result{}, err
	}
	paymentsTotal.WithLabelValues(string(p.Status)).Inc()
	if p.Status == StatusCaptured {
		paymentAmount.WithLabelValues(p.Currency).Add(float64(p.Amount))
	}
	return Result{Status: status, Body: body}, nil
}

// drive advances the payment until it reaches a terminal state.
func (s *Service) drive(ctx context.Context, p Payment, cardToken string) (Payment, error) {
	for !p.Status.Terminal() {
		var err error
		switch p.Status {
		case StatusPending:
			var ref string
			ref, err = s.processor.Authorize(ctx, p, cardToken)
			switch {
			case errors.Is(err, ErrDeclined):
				p, err = s.store.Transition(ctx, p, StatusFailed, "card_declined", "", EventFailed)
			case err != nil:
				return p, fmt.Errorf("authorize: %w", err)
			default:
				p, err = s.store.Transition(ctx, p, StatusAuthorized, "", ref, "")
			}
		case StatusAuthorized:
			if err = s.processor.Capture(ctx, p, p.ProcessorRef); err != nil {
				return p, fmt.Errorf("capture: %w", err)
			}
			if err = s.ledger.RecordCapture(ctx, p); err != nil {
				return p, fmt.Errorf("record in ledger: %w", err)
			}
			p, err = s.store.Transition(ctx, p, StatusCaptured, "", "", EventCaptured)
		default:
			return p, ErrIllegalTransition{From: p.Status}
		}
		if err != nil {
			return p, err
		}
	}
	return p, nil
}

// Get returns a payment.
func (s *Service) Get(ctx context.Context, id uuid.UUID) (Payment, error) {
	return s.store.Get(ctx, id)
}
