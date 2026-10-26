package ledger

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/minhhieu21193/fincore/internal/platform/pgtest"
)

func newStore(t *testing.T) (*Store, *pgxpool.Pool) {
	t.Helper()
	pool := pgtest.New(t)
	if err := Migrate(context.Background(), pool); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return NewStore(pool), pool
}

func TestPostAndDerivedBalances(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()

	if _, created, err := s.Post(ctx, validInput()); err != nil || !created {
		t.Fatalf("Post: created=%v err=%v", created, err)
	}
	second := validInput()
	second.ExternalRef = "payment:2:capture"
	if _, _, err := s.Post(ctx, second); err != nil {
		t.Fatalf("Post second: %v", err)
	}

	want := map[string]int64{
		"assets:processor_receivable": 2000,
		"liabilities:merchant:m_1":    1942,
		"revenue:fees":                58,
	}
	for code, w := range want {
		b, err := s.Balance(ctx, code)
		if err != nil {
			t.Fatalf("Balance(%s): %v", code, err)
		}
		if b.Balance != w {
			t.Errorf("Balance(%s) = %d, want %d", code, b.Balance, w)
		}
	}
	imb, err := s.Imbalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if imb["USD"] != 0 {
		t.Fatalf("ledger imbalance = %d, want 0", imb["USD"])
	}
}

func TestPostIsIdempotent(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()

	first, created, err := s.Post(ctx, validInput())
	if err != nil || !created {
		t.Fatalf("first post: created=%v err=%v", created, err)
	}
	again, created, err := s.Post(ctx, validInput())
	if err != nil || created {
		t.Fatalf("replay: created=%v err=%v", created, err)
	}
	if again.ID != first.ID {
		t.Fatalf("replay returned a different transaction: %s vs %s", again.ID, first.ID)
	}

	conflicting := validInput()
	conflicting.Entries[1].Amount, conflicting.Entries[2].Amount = 900, 100
	if _, _, err := s.Post(ctx, conflicting); !errors.Is(err, ErrConflict) {
		t.Fatalf("conflicting reuse: err=%v, want ErrConflict", err)
	}
}

func TestConcurrentIdenticalPostsCreateOneTransaction(t *testing.T) {
	s, pool := newStore(t)
	ctx := context.Background()

	var wg sync.WaitGroup
	errs := make(chan error, 10)
	for range 10 {
		wg.Go(func() {
			if _, _, err := s.Post(ctx, validInput()); err != nil {
				errs <- err
			}
		})
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent post: %v", err)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM entries`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Fatalf("entries = %d, want 3", n)
	}
}

// The database must reject unbalanced writes even when the application-level
// validation is bypassed entirely.
func TestDatabaseRejectsUnbalancedTransaction(t *testing.T) {
	_, pool := newStore(t)
	ctx := context.Background()

	if _, err := pool.Exec(ctx, `INSERT INTO accounts (code, type, currency) VALUES
		('assets:cash', 'asset', 'USD'), ('liabilities:merchant:m_1', 'liability', 'USD')`); err != nil {
		t.Fatal(err)
	}

	cases := map[string]string{
		"unbalanced": `
			INSERT INTO entries (transaction_id, account_id, direction, amount, currency) VALUES
			  ($1, (SELECT id FROM accounts WHERE code='assets:cash'), 'debit', 100, 'USD'),
			  ($1, (SELECT id FROM accounts WHERE code='liabilities:merchant:m_1'), 'credit', 99, 'USD')`,
		"single entry": `
			INSERT INTO entries (transaction_id, account_id, direction, amount, currency) VALUES
			  ($1, (SELECT id FROM accounts WHERE code='assets:cash'), 'debit', 100, 'USD')`,
		"no entries": ``,
		"mixed currency": `
			INSERT INTO entries (transaction_id, account_id, direction, amount, currency) VALUES
			  ($1, (SELECT id FROM accounts WHERE code='assets:cash'), 'debit', 100, 'USD'),
			  ($1, (SELECT id FROM accounts WHERE code='liabilities:merchant:m_1'), 'credit', 100, 'EUR')`,
	}
	for name, entriesSQL := range cases {
		t.Run(name, func(t *testing.T) {
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(ctx) }()
			id := uuid.New()
			if _, err := tx.Exec(ctx, `INSERT INTO transactions (id, external_ref, currency, request_hash)
				VALUES ($1, $2, 'USD', '\x00')`, id, fmt.Sprintf("raw:%s", id)); err != nil {
				t.Fatal(err)
			}
			if entriesSQL != "" {
				if _, err := tx.Exec(ctx, entriesSQL, id); err != nil {
					// Mixed currency is still caught at commit; any insert error here is unexpected.
					t.Fatalf("insert entries: %v", err)
				}
			}
			err = tx.Commit(ctx)
			if err == nil {
				t.Fatal("commit succeeded; the database accepted an invalid ledger transaction")
			}
			if !strings.Contains(err.Error(), "SQLSTATE 23514") {
				t.Fatalf("commit error = %v, want check_violation (23514)", err)
			}
		})
	}
}

func TestEntriesAreAppendOnly(t *testing.T) {
	s, pool := newStore(t)
	ctx := context.Background()
	if _, _, err := s.Post(ctx, validInput()); err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`UPDATE entries SET amount = amount + 1`,
		`DELETE FROM entries`,
		`UPDATE transactions SET description = 'tampered'`,
		`DELETE FROM transactions`,
		`TRUNCATE entries CASCADE`,
	} {
		if _, err := pool.Exec(ctx, stmt); err == nil {
			t.Errorf("%q succeeded; ledger must be append-only", stmt)
		}
	}
}
