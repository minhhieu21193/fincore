package payments

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/minhhieu21193/fincore/internal/platform/migrate"
)

//go:embed migrations/*.sql
var migrations embed.FS

// Migrate applies the payments schema.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	return migrate.Up(ctx, pool, migrations, "migrations", "payments-api")
}

// Errors surfaced to API callers.
var (
	ErrKeyReuse       = errors.New("idempotency key reused with a different request")
	ErrInFlight       = errors.New("a request with this idempotency key is still being processed")
	ErrNotFound       = errors.New("payment not found")
	ErrConcurrentMove = errors.New("payment state changed concurrently")
)

// Payment is the payment aggregate.
type Payment struct {
	ID            uuid.UUID `json:"id"`
	MerchantID    string    `json:"merchant_id"`
	Amount        int64     `json:"amount"`
	Currency      string    `json:"currency"`
	Status        Status    `json:"status"`
	FailureReason string    `json:"failure_reason,omitempty"`
	ProcessorRef  string    `json:"-"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// StoredResponse is the response recorded for an idempotency key.
type StoredResponse struct {
	Status int
	Body   []byte
}

// Claim is the result of reserving an idempotency key.
type Claim struct {
	Payment Payment
	Replay  *StoredResponse // set when the key already has a final response
	Resumed bool            // true when a stale in-flight request was taken over
}

// Event is published to the payment events queue via the outbox.
type Event struct {
	EventID    uuid.UUID `json:"event_id"`
	Type       string    `json:"type"`
	OccurredAt time.Time `json:"occurred_at"`
	Payment    Payment   `json:"payment"`
}

// Store is the payments persistence layer.
type Store struct {
	pool    *pgxpool.Pool
	lockTTL time.Duration
}

// NewStore returns a Store. lockTTL is how long an in-flight idempotency key
// stays locked before a retry may take over (e.g. after a pod crash).
func NewStore(pool *pgxpool.Pool, lockTTL time.Duration) *Store {
	return &Store{pool: pool, lockTTL: lockTTL}
}

const paymentColumns = `id, merchant_id, amount, currency, status, coalesce(failure_reason, ''), coalesce(processor_ref, ''), created_at, updated_at`

func scanPayment(row pgx.Row) (Payment, error) {
	var p Payment
	err := row.Scan(&p.ID, &p.MerchantID, &p.Amount, &p.Currency, &p.Status, &p.FailureReason, &p.ProcessorRef, &p.CreatedAt, &p.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Payment{}, ErrNotFound
	}
	return p, err
}

// Claim reserves (merchantID, key) for this request. A brand-new key creates
// the payment in pending state. An existing key either replays the stored
// response, rejects a different request body, rejects a concurrent duplicate,
// or (when the previous attempt's lock went stale) hands the existing payment
// back so processing resumes from its current state.
func (s *Store) Claim(ctx context.Context, p Payment, key string, requestHash []byte) (Claim, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Claim{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	created, err := scanPayment(tx.QueryRow(ctx, `
		INSERT INTO payments (id, merchant_id, amount, currency, status)
		VALUES ($1, $2, $3, $4, 'pending')
		RETURNING `+paymentColumns, p.ID, p.MerchantID, p.Amount, p.Currency))
	if err != nil {
		return Claim{}, err
	}
	tag, err := tx.Exec(ctx, `
		INSERT INTO idempotency_keys (merchant_id, key, request_hash, payment_id, locked_at)
		VALUES ($1, $2, $3, $4, now())
		ON CONFLICT (merchant_id, key) DO NOTHING`, p.MerchantID, key, requestHash, p.ID)
	if err != nil {
		return Claim{}, err
	}
	if tag.RowsAffected() == 1 {
		return Claim{Payment: created}, tx.Commit(ctx)
	}
	_ = tx.Rollback(ctx) // discard the speculative payment row
	return s.claimExisting(ctx, p.MerchantID, key, requestHash)
}

func (s *Store) claimExisting(ctx context.Context, merchantID, key string, requestHash []byte) (Claim, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Claim{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var (
		storedHash []byte
		paymentID  uuid.UUID
		respStatus *int
		respBody   []byte
		lockFresh  bool
	)
	err = tx.QueryRow(ctx, `
		SELECT request_hash, payment_id, response_status, response_body,
		       coalesce(locked_at > now() - make_interval(secs => $3), false)
		FROM idempotency_keys
		WHERE merchant_id = $1 AND key = $2
		FOR UPDATE`, merchantID, key, s.lockTTL.Seconds()).
		Scan(&storedHash, &paymentID, &respStatus, &respBody, &lockFresh)
	if err != nil {
		return Claim{}, err
	}
	if !bytes.Equal(storedHash, requestHash) {
		return Claim{}, ErrKeyReuse
	}
	if respStatus != nil {
		return Claim{Replay: &StoredResponse{Status: *respStatus, Body: respBody}}, nil
	}
	if lockFresh {
		return Claim{}, ErrInFlight
	}
	if _, err := tx.Exec(ctx, `UPDATE idempotency_keys SET locked_at = now() WHERE merchant_id = $1 AND key = $2`, merchantID, key); err != nil {
		return Claim{}, err
	}
	p, err := scanPayment(tx.QueryRow(ctx, `SELECT `+paymentColumns+` FROM payments WHERE id = $1`, paymentID))
	if err != nil {
		return Claim{}, err
	}
	return Claim{Payment: p, Resumed: true}, tx.Commit(ctx)
}

// Transition moves a payment from one state to another with an optimistic
// guard (WHERE status = from). If eventType is non-empty, an outbox event is
// written in the same database transaction, so the state change and its
// notification are committed atomically.
func (s *Store) Transition(ctx context.Context, p Payment, to Status, failureReason, processorRef, eventType string) (Payment, error) {
	if !CanTransition(p.Status, to) {
		return Payment{}, ErrIllegalTransition{From: p.Status, To: to}
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Payment{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	next, err := scanPayment(tx.QueryRow(ctx, `
		UPDATE payments
		SET status = $3,
		    failure_reason = coalesce(nullif($4, ''), failure_reason),
		    processor_ref  = coalesce(nullif($5, ''), processor_ref)
		WHERE id = $1 AND status = $2
		RETURNING `+paymentColumns, p.ID, p.Status, to, failureReason, processorRef))
	if errors.Is(err, ErrNotFound) {
		return Payment{}, ErrConcurrentMove
	}
	if err != nil {
		return Payment{}, err
	}
	if eventType != "" {
		ev := Event{EventID: uuid.New(), Type: eventType, OccurredAt: next.UpdatedAt.UTC(), Payment: next}
		payload, err := json.Marshal(ev)
		if err != nil {
			return Payment{}, err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO outbox (event_id, aggregate_id, event_type, payload)
			VALUES ($1, $2, $3, $4)`, ev.EventID, next.ID, eventType, payload); err != nil {
			return Payment{}, err
		}
	}
	return next, tx.Commit(ctx)
}

// SaveResponse records the final response for the key and releases its lock.
func (s *Store) SaveResponse(ctx context.Context, merchantID, key string, status int, body []byte) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE idempotency_keys
		SET response_status = $3, response_body = $4, locked_at = NULL
		WHERE merchant_id = $1 AND key = $2`, merchantID, key, status, body)
	return err
}

// ReleaseLock lets an immediate retry resume after a technical failure.
func (s *Store) ReleaseLock(ctx context.Context, merchantID, key string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE idempotency_keys SET locked_at = NULL
		WHERE merchant_id = $1 AND key = $2 AND response_status IS NULL`, merchantID, key)
	return err
}

// Get loads a payment.
func (s *Store) Get(ctx context.Context, id uuid.UUID) (Payment, error) {
	return scanPayment(s.pool.QueryRow(ctx, `SELECT `+paymentColumns+` FROM payments WHERE id = $1`, id))
}

// OutboxMessage is an unpublished outbox row.
type OutboxMessage struct {
	ID        int64
	EventID   uuid.UUID
	EventType string
	Payload   []byte
}

// Publisher delivers outbox messages to the event queue. It returns the IDs
// that were accepted; the rest stay in the outbox and are retried.
type Publisher interface {
	Publish(ctx context.Context, msgs []OutboxMessage) (accepted []int64, err error)
}

// RelayOnce publishes up to batch unpublished events. FOR UPDATE SKIP LOCKED
// lets every replica run a relay concurrently without double-sending a row.
// Delivery is at-least-once (a crash after Publish and before COMMIT resends);
// consumers deduplicate on event_id.
func (s *Store) RelayOnce(ctx context.Context, pub Publisher, batch int) (int, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	rows, err := tx.Query(ctx, `
		SELECT id, event_id, event_type, payload FROM outbox
		WHERE published_at IS NULL
		ORDER BY id
		LIMIT $1
		FOR UPDATE SKIP LOCKED`, batch)
	if err != nil {
		return 0, err
	}
	msgs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (OutboxMessage, error) {
		var m OutboxMessage
		err := r.Scan(&m.ID, &m.EventID, &m.EventType, &m.Payload)
		return m, err
	})
	if err != nil || len(msgs) == 0 {
		return 0, err
	}
	accepted, pubErr := pub.Publish(ctx, msgs)
	ids := make([]int64, len(msgs))
	for i, m := range msgs {
		ids[i] = m.ID
	}
	if _, err := tx.Exec(ctx, `UPDATE outbox SET attempts = attempts + 1 WHERE id = ANY($1)`, ids); err != nil {
		return 0, err
	}
	if len(accepted) > 0 {
		if _, err := tx.Exec(ctx, `UPDATE outbox SET published_at = now() WHERE id = ANY($1)`, accepted); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return len(accepted), pubErr
}

// OutboxBacklog returns the number of unpublished events.
func (s *Store) OutboxBacklog(ctx context.Context) (int64, error) {
	var n int64
	err := s.pool.QueryRow(ctx, `SELECT count(*) FROM outbox WHERE published_at IS NULL`).Scan(&n)
	return n, err
}
