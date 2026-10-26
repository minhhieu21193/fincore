package payments

import (
	"context"
	"errors"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/google/uuid"
)

// ErrDeclined is a business failure: the card was declined. The payment
// moves to failed and the API answers 402.
var ErrDeclined = errors.New("card declined")

// ErrProcessorUnavailable is a technical failure: the request may be retried
// with the same Idempotency-Key and processing resumes where it stopped.
var ErrProcessorUnavailable = errors.New("card processor unavailable")

// Processor is a card network gateway.
type Processor interface {
	Authorize(ctx context.Context, p Payment, cardToken string) (ref string, err error)
	Capture(ctx context.Context, p Payment, ref string) error
}

// FakeProcessor simulates a card processor with configurable latency and
// decline rate. Card token "tok_decline" is always declined and
// "tok_unavailable" always times out, which makes demos and tests deterministic.
type FakeProcessor struct {
	Latency     time.Duration
	Jitter      time.Duration
	DeclineRate float64

	mu  sync.Mutex
	rnd *rand.Rand
}

// NewFakeProcessor returns a processor using a time-seeded random source.
func NewFakeProcessor(latency, jitter time.Duration, declineRate float64) *FakeProcessor {
	now := uint64(time.Now().UnixNano()) //nolint:gosec // simulation only
	return &FakeProcessor{
		Latency: latency, Jitter: jitter, DeclineRate: declineRate,
		rnd: rand.New(rand.NewPCG(now, now>>1)), //nolint:gosec // simulation only, not security relevant
	}
}

func (f *FakeProcessor) float() float64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.rnd.Float64()
}

func (f *FakeProcessor) wait(ctx context.Context) error {
	d := f.Latency
	if f.Jitter > 0 {
		d += time.Duration(f.float() * float64(f.Jitter))
	}
	select {
	case <-time.After(d):
		return nil
	case <-ctx.Done():
		return ErrProcessorUnavailable
	}
}

// Authorize places a hold on the card.
func (f *FakeProcessor) Authorize(ctx context.Context, _ Payment, cardToken string) (string, error) {
	if cardToken == "tok_unavailable" {
		return "", ErrProcessorUnavailable
	}
	if err := f.wait(ctx); err != nil {
		return "", err
	}
	if cardToken == "tok_decline" || f.float() < f.DeclineRate {
		return "", ErrDeclined
	}
	return "auth_" + uuid.NewString(), nil
}

// Capture settles a previous authorization. Capturing the same ref twice is
// a no-op at the processor, so retries are safe.
func (f *FakeProcessor) Capture(ctx context.Context, _ Payment, _ string) error {
	return f.wait(ctx)
}
