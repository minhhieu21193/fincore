package ledger

import (
	"bytes"
	"context"
	"embed"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/minhhieu21193/fincore/internal/platform/migrate"
)

//go:embed migrations/*.sql
var migrations embed.FS

// Migrate applies the ledger schema.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	return migrate.Up(ctx, pool, migrations, "migrations", "ledger")
}

// Store persists ledger transactions.
type Store struct {
	pool *pgxpool.Pool
}

// NewStore returns a Store backed by pool.
func NewStore(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

// Post records a balanced transaction. It is idempotent on ExternalRef: the
// same request returns the original transaction with created=false, while a
// different request reusing the ref fails with ErrConflict.
func (s *Store) Post(ctx context.Context, in TransactionInput) (Transaction, bool, error) {
	if err := in.Validate(); err != nil {
		return Transaction{}, false, err
	}
	hash := in.Hash()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Transaction{}, false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	id := uuid.New()
	tag, err := tx.Exec(ctx, `
		INSERT INTO transactions (id, external_ref, description, currency, request_hash)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (external_ref) DO NOTHING`,
		id, in.ExternalRef, in.Description, in.Currency, hash)
	if err != nil {
		return Transaction{}, false, err
	}
	if tag.RowsAffected() == 0 {
		_ = tx.Rollback(ctx)
		return s.replay(ctx, in.ExternalRef, hash)
	}

	for _, e := range in.Entries {
		accountID, err := ensureAccount(ctx, tx, e.Account, in.Currency)
		if err != nil {
			return Transaction{}, false, err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO entries (transaction_id, account_id, direction, amount, currency)
			VALUES ($1, $2, $3, $4, $5)`,
			id, accountID, e.Direction, e.Amount, in.Currency); err != nil {
			return Transaction{}, false, err
		}
	}
	// The deferred balance triggers run here.
	if err := tx.Commit(ctx); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23514" {
			return Transaction{}, false, fmt.Errorf("%w: %s", ErrInvalid, pgErr.Message)
		}
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			// Lost a race with a concurrent identical request.
			return s.replay(ctx, in.ExternalRef, hash)
		}
		return Transaction{}, false, err
	}
	t, err := s.GetByExternalRef(ctx, in.ExternalRef)
	return t, true, err
}

func (s *Store) replay(ctx context.Context, ref string, hash []byte) (Transaction, bool, error) {
	var existing []byte
	if err := s.pool.QueryRow(ctx, `SELECT request_hash FROM transactions WHERE external_ref = $1`, ref).Scan(&existing); err != nil {
		return Transaction{}, false, err
	}
	if !bytes.Equal(existing, hash) {
		return Transaction{}, false, ErrConflict
	}
	t, err := s.GetByExternalRef(ctx, ref)
	return t, false, err
}

func ensureAccount(ctx context.Context, tx pgx.Tx, code, currency string) (int64, error) {
	typ, err := AccountTypeFor(code)
	if err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO accounts (code, type, currency) VALUES ($1, $2, $3)
		ON CONFLICT (code) DO NOTHING`, code, typ, currency); err != nil {
		return 0, err
	}
	var id int64
	var ccy string
	if err := tx.QueryRow(ctx, `SELECT id, currency FROM accounts WHERE code = $1`, code).Scan(&id, &ccy); err != nil {
		return 0, err
	}
	if ccy != currency {
		return 0, fmt.Errorf("%w: %s is %s", ErrCurrencyClash, code, ccy)
	}
	return id, nil
}

// GetByExternalRef loads a transaction and its entries.
func (s *Store) GetByExternalRef(ctx context.Context, ref string) (Transaction, error) {
	var t Transaction
	err := s.pool.QueryRow(ctx, `
		SELECT id, external_ref, currency, description, created_at
		FROM transactions WHERE external_ref = $1`, ref).
		Scan(&t.ID, &t.ExternalRef, &t.Currency, &t.Description, &t.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Transaction{}, ErrNotFound
	}
	if err != nil {
		return Transaction{}, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT a.code, e.direction, e.amount
		FROM entries e JOIN accounts a ON a.id = e.account_id
		WHERE e.transaction_id = $1 ORDER BY e.id`, t.ID)
	if err != nil {
		return Transaction{}, err
	}
	t.Entries, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Entry, error) {
		var e Entry
		err := r.Scan(&e.Account, &e.Direction, &e.Amount)
		return e, err
	})
	return t, err
}

// Balance derives an account's balance from its entries.
func (s *Store) Balance(ctx context.Context, code string) (Balance, error) {
	b := Balance{Account: code}
	err := s.pool.QueryRow(ctx, `
		SELECT a.type, a.currency,
		       coalesce(sum(e.amount) FILTER (WHERE e.direction = 'debit'), 0),
		       coalesce(sum(e.amount) FILTER (WHERE e.direction = 'credit'), 0)
		FROM accounts a LEFT JOIN entries e ON e.account_id = a.id
		WHERE a.code = $1
		GROUP BY a.type, a.currency`, code).
		Scan(&b.Type, &b.Currency, &b.Debits, &b.Credits)
	if errors.Is(err, pgx.ErrNoRows) {
		return Balance{}, ErrNotFound
	}
	if err != nil {
		return Balance{}, err
	}
	b.Balance = NormalBalance(b.Type, b.Debits, b.Credits)
	return b, nil
}

// ClaimCheck reports whether this instance should run the named fleet-wide
// check now. It atomically moves the check's last run forward when that run is
// at least every old, so across all replicas the check runs about once per
// interval, whatever the replica count.
func (s *Store) ClaimCheck(ctx context.Context, name string, every time.Duration) (bool, error) {
	tag, err := s.pool.Exec(ctx, `
		UPDATE invariant_checks SET checked_at = now()
		WHERE name = $1 AND checked_at <= now() - make_interval(secs => $2)`, name, every.Seconds())
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// Imbalance returns sum(debits) - sum(credits) per currency across the whole
// ledger. Every value must always be zero; it is exported as a metric.
func (s *Store) Imbalance(ctx context.Context) (map[string]int64, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT currency,
		       coalesce(sum(amount) FILTER (WHERE direction = 'debit'), 0)
		     - coalesce(sum(amount) FILTER (WHERE direction = 'credit'), 0)
		FROM entries GROUP BY currency`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int64{}
	for rows.Next() {
		var ccy string
		var diff int64
		if err := rows.Scan(&ccy, &diff); err != nil {
			return nil, err
		}
		out[ccy] = diff
	}
	return out, rows.Err()
}
