// Package ledger implements a double-entry ledger on PostgreSQL.
package ledger

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Direction is the side of an entry.
type Direction string

// Entry directions.
const (
	Debit  Direction = "debit"
	Credit Direction = "credit"
)

// AccountType decides on which side an account's balance normally sits.
type AccountType string

// Account types.
const (
	Asset     AccountType = "asset"
	Liability AccountType = "liability"
	Equity    AccountType = "equity"
	Revenue   AccountType = "revenue"
	Expense   AccountType = "expense"
)

// Validation errors returned to API callers as 422.
var (
	ErrInvalid        = errors.New("invalid transaction")
	ErrConflict       = errors.New("external_ref already used with a different request")
	ErrNotFound       = errors.New("not found")
	ErrCurrencyClash  = errors.New("account exists with a different currency")
	accountCodeRegexp = regexp.MustCompile(`^[a-z_]+(:[A-Za-z0-9_.-]+)+$`)
	currencyRegexp    = regexp.MustCompile(`^[A-Z]{3}$`)
)

// EntryInput is one leg of a transaction request.
type EntryInput struct {
	Account   string    `json:"account"`
	Direction Direction `json:"direction"`
	Amount    int64     `json:"amount"`
}

// TransactionInput is the body of POST /v1/transactions.
type TransactionInput struct {
	ExternalRef string       `json:"external_ref"`
	Currency    string       `json:"currency"`
	Description string       `json:"description,omitempty"`
	Entries     []EntryInput `json:"entries"`
}

// Entry is a persisted ledger line.
type Entry struct {
	Account   string    `json:"account"`
	Direction Direction `json:"direction"`
	Amount    int64     `json:"amount"`
}

// Transaction is a persisted, balanced set of entries.
type Transaction struct {
	ID          uuid.UUID `json:"id"`
	ExternalRef string    `json:"external_ref"`
	Currency    string    `json:"currency"`
	Description string    `json:"description"`
	Entries     []Entry   `json:"entries"`
	CreatedAt   time.Time `json:"created_at"`
}

// Balance is an account balance derived from its entries.
type Balance struct {
	Account  string      `json:"account"`
	Type     AccountType `json:"type"`
	Currency string      `json:"currency"`
	Debits   int64       `json:"debits"`
	Credits  int64       `json:"credits"`
	// Balance is expressed on the account's normal side: debits-credits for
	// assets and expenses, credits-debits for liabilities, equity and revenue.
	Balance int64 `json:"balance"`
}

// AccountTypeFor derives the account type from the code's first segment,
// e.g. "liabilities:merchant:m_1" -> liability.
func AccountTypeFor(code string) (AccountType, error) {
	if !accountCodeRegexp.MatchString(code) {
		return "", fmt.Errorf("%w: malformed account code %q", ErrInvalid, code)
	}
	switch prefix, _, _ := strings.Cut(code, ":"); prefix {
	case "assets":
		return Asset, nil
	case "liabilities":
		return Liability, nil
	case "equity":
		return Equity, nil
	case "revenue":
		return Revenue, nil
	case "expenses":
		return Expense, nil
	default:
		return "", fmt.Errorf("%w: unknown account class %q", ErrInvalid, prefix)
	}
}

// NormalBalance returns the balance on the account type's normal side.
func NormalBalance(t AccountType, debits, credits int64) int64 {
	switch t {
	case Asset, Expense:
		return debits - credits
	default:
		return credits - debits
	}
}

// Validate checks the request before it reaches the database. The database
// enforces the same balancing rule independently.
func (in TransactionInput) Validate() error {
	if in.ExternalRef == "" || len(in.ExternalRef) > 200 {
		return fmt.Errorf("%w: external_ref must be 1..200 characters", ErrInvalid)
	}
	if !currencyRegexp.MatchString(in.Currency) {
		return fmt.Errorf("%w: currency must be an ISO-4217 code", ErrInvalid)
	}
	if len(in.Entries) < 2 {
		return fmt.Errorf("%w: at least two entries are required", ErrInvalid)
	}
	var debits, credits int64
	for i, e := range in.Entries {
		if _, err := AccountTypeFor(e.Account); err != nil {
			return fmt.Errorf("entry %d: %w", i, err)
		}
		if e.Amount <= 0 {
			return fmt.Errorf("%w: entry %d amount must be positive", ErrInvalid, i)
		}
		switch e.Direction {
		case Debit:
			debits += e.Amount
		case Credit:
			credits += e.Amount
		default:
			return fmt.Errorf("%w: entry %d direction must be debit or credit", ErrInvalid, i)
		}
		if debits < 0 || credits < 0 {
			return fmt.Errorf("%w: amount overflow", ErrInvalid)
		}
	}
	if debits != credits {
		return fmt.Errorf("%w: debits (%d) must equal credits (%d)", ErrInvalid, debits, credits)
	}
	return nil
}

// Hash fingerprints the request so a replay with the same external_ref can be
// told apart from a conflicting reuse.
func (in TransactionInput) Hash() []byte {
	b, _ := json.Marshal(in) //nolint:errchkjson // plain struct, cannot fail
	sum := sha256.Sum256(b)
	return sum[:]
}
