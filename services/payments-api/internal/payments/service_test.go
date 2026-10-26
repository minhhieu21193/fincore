package payments

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/minhhieu21193/fincore/internal/platform/pgtest"
)

type fakeLedger struct {
	calls    atomic.Int32
	failNext atomic.Int32 // number of upcoming calls that fail
}

func (l *fakeLedger) RecordCapture(context.Context, Payment) error {
	l.calls.Add(1)
	if l.failNext.Load() > 0 {
		l.failNext.Add(-1)
		return errors.New("ledger down")
	}
	return nil
}

type fakePublisher struct {
	mu   sync.Mutex
	sent []OutboxMessage
}

func (p *fakePublisher) Publish(_ context.Context, msgs []OutboxMessage) ([]int64, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	ids := make([]int64, len(msgs))
	for i, m := range msgs {
		p.sent = append(p.sent, m)
		ids[i] = m.ID
	}
	return ids, nil
}

type env struct {
	svc    *Service
	store  *Store
	ledger *fakeLedger
	pool   *pgxpool.Pool
}

func newEnv(t *testing.T, lockTTL time.Duration) env {
	t.Helper()
	pool := pgtest.New(t)
	if err := Migrate(context.Background(), pool); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	store := NewStore(pool, lockTTL)
	l := &fakeLedger{}
	return env{svc: NewService(store, NewFakeProcessor(0, 0, 0), l), store: store, ledger: l, pool: pool}
}

func req() CreateRequest {
	return CreateRequest{MerchantID: "m_1", Amount: 1000, Currency: "USD", CardToken: "tok_visa"}
}

func decode(t *testing.T, b []byte) Payment {
	t.Helper()
	var p Payment
	if err := json.Unmarshal(b, &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return p
}

func TestCreateCapturesAndWritesOutbox(t *testing.T) {
	e := newEnv(t, 30*time.Second)
	ctx := context.Background()

	res, err := e.svc.Create(ctx, "key-1", req())
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != http.StatusCreated || decode(t, res.Body).Status != StatusCaptured {
		t.Fatalf("got %d %s, want 201 captured", res.Status, res.Body)
	}
	if e.ledger.calls.Load() != 1 {
		t.Fatalf("ledger calls = %d, want 1", e.ledger.calls.Load())
	}

	pub := &fakePublisher{}
	if n, err := e.store.RelayOnce(ctx, pub, 10); err != nil || n != 1 {
		t.Fatalf("RelayOnce = %d, %v; want 1 event", n, err)
	}
	var ev Event
	if err := json.Unmarshal(pub.sent[0].Payload, &ev); err != nil {
		t.Fatal(err)
	}
	if ev.Type != EventCaptured || ev.Payment.ID != decode(t, res.Body).ID {
		t.Fatalf("unexpected event %+v", ev)
	}
	if n, _ := e.store.RelayOnce(ctx, pub, 10); n != 0 {
		t.Fatalf("event relayed twice")
	}
}

func TestIdempotentReplayAndKeyReuse(t *testing.T) {
	e := newEnv(t, 30*time.Second)
	ctx := context.Background()

	first, err := e.svc.Create(ctx, "key-1", req())
	if err != nil {
		t.Fatal(err)
	}
	again, err := e.svc.Create(ctx, "key-1", req())
	if err != nil {
		t.Fatal(err)
	}
	if !again.Replayed || again.Status != first.Status || string(again.Body) != string(first.Body) {
		t.Fatalf("replay mismatch:\nfirst  %d %s\nreplay %d %s (replayed=%v)", first.Status, first.Body, again.Status, again.Body, again.Replayed)
	}
	if e.ledger.calls.Load() != 1 {
		t.Fatalf("ledger called %d times; a replay must not re-post", e.ledger.calls.Load())
	}

	other := req()
	other.Amount = 2000
	if _, err := e.svc.Create(ctx, "key-1", other); !errors.Is(err, ErrKeyReuse) {
		t.Fatalf("key reuse with different body: err=%v, want ErrKeyReuse", err)
	}
	// Same key, different merchant: independent.
	other = req()
	other.MerchantID = "m_2"
	if res, err := e.svc.Create(ctx, "key-1", other); err != nil || res.Replayed {
		t.Fatalf("other merchant: %v replayed=%v", err, res.Replayed)
	}
}

func TestDeclineIsFinalAndReplayed(t *testing.T) {
	e := newEnv(t, 30*time.Second)
	ctx := context.Background()
	r := req()
	r.CardToken = "tok_decline"

	res, err := e.svc.Create(ctx, "key-d", r)
	if err != nil {
		t.Fatal(err)
	}
	p := decode(t, res.Body)
	if res.Status != http.StatusPaymentRequired || p.Status != StatusFailed || p.FailureReason != "card_declined" {
		t.Fatalf("got %d %+v", res.Status, p)
	}
	if e.ledger.calls.Load() != 0 {
		t.Fatal("declined payment must not touch the ledger")
	}
	pub := &fakePublisher{}
	if n, _ := e.store.RelayOnce(ctx, pub, 10); n != 1 || pub.sent[0].EventType != EventFailed {
		t.Fatalf("want one payment.failed event, got %d", n)
	}
}

func TestRetryResumesAfterLedgerOutage(t *testing.T) {
	e := newEnv(t, 30*time.Second)
	ctx := context.Background()
	e.ledger.failNext.Store(1)

	if _, err := e.svc.Create(ctx, "key-r", req()); err == nil {
		t.Fatal("expected an error while the ledger is down")
	}
	res, err := e.svc.Create(ctx, "key-r", req())
	if err != nil {
		t.Fatalf("retry: %v", err)
	}
	p := decode(t, res.Body)
	if res.Status != http.StatusCreated || p.Status != StatusCaptured || res.Replayed {
		t.Fatalf("retry got %d %+v", res.Status, p)
	}
	var n int
	if err := e.pool.QueryRow(ctx, `SELECT count(*) FROM payments`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("payments rows = %d (%v); the retry must resume the same payment", n, err)
	}
}

func TestConcurrentDuplicatesProcessOnce(t *testing.T) {
	e := newEnv(t, 30*time.Second)
	ctx := context.Background()

	var wg sync.WaitGroup
	var ok, inFlight atomic.Int32
	for range 8 {
		wg.Go(func() {
			_, err := e.svc.Create(ctx, "key-c", req())
			switch {
			case err == nil:
				ok.Add(1)
			case errors.Is(err, ErrInFlight):
				inFlight.Add(1)
			default:
				t.Errorf("unexpected error: %v", err)
			}
		})
	}
	wg.Wait()
	if e.ledger.calls.Load() != 1 {
		t.Fatalf("ledger calls = %d, want exactly 1", e.ledger.calls.Load())
	}
	if ok.Load()+inFlight.Load() != 8 || ok.Load() < 1 {
		t.Fatalf("ok=%d inFlight=%d", ok.Load(), inFlight.Load())
	}
}

func TestDatabaseRejectsIllegalTransition(t *testing.T) {
	e := newEnv(t, 30*time.Second)
	ctx := context.Background()
	res, err := e.svc.Create(ctx, "key-x", req())
	if err != nil {
		t.Fatal(err)
	}
	p := decode(t, res.Body)
	for _, to := range []Status{StatusPending, StatusAuthorized, StatusFailed} {
		if _, err := e.pool.Exec(ctx, `UPDATE payments SET status = $2 WHERE id = $1`, p.ID, to); err == nil {
			t.Errorf("database allowed captured -> %s", to)
		}
	}
	if _, err := e.store.Transition(ctx, p, StatusFailed, "x", "", ""); err == nil {
		t.Error("store allowed captured -> failed")
	}
}
