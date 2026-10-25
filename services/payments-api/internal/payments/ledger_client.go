package payments

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/minhhieu21193/fincore/internal/platform/httpx"
)

// Ledger records captured money movements.
type Ledger interface {
	RecordCapture(ctx context.Context, p Payment) error
}

// LedgerClient calls the ledger service over HTTP.
type LedgerClient struct {
	BaseURL string
	FeeBps  int64 // platform fee in basis points, e.g. 290 = 2.90%
	HTTP    *http.Client
}

// NewLedgerClient returns a client with tracing and a request timeout.
func NewLedgerClient(baseURL string, feeBps int64) *LedgerClient {
	return &LedgerClient{BaseURL: baseURL, FeeBps: feeBps, HTTP: httpx.Client(5 * time.Second)}
}

type ledgerEntry struct {
	Account   string `json:"account"`
	Direction string `json:"direction"`
	Amount    int64  `json:"amount"`
}

type ledgerTransaction struct {
	ExternalRef string        `json:"external_ref"`
	Currency    string        `json:"currency"`
	Description string        `json:"description"`
	Entries     []ledgerEntry `json:"entries"`
}

// CaptureEntries returns the balanced double-entry legs for a capture:
//
//	Dr assets:processor_receivable           amount
//	  Cr liabilities:merchant:<merchant_id>  amount - fee
//	  Cr revenue:fees                        fee
func CaptureEntries(p Payment, feeBps int64) []ledgerEntry {
	fee := p.Amount * feeBps / 10_000
	entries := []ledgerEntry{{Account: "assets:processor_receivable", Direction: "debit", Amount: p.Amount}}
	// Zero-amount legs are omitted; the ledger only accepts positive amounts.
	if net := p.Amount - fee; net > 0 {
		entries = append(entries, ledgerEntry{Account: "liabilities:merchant:" + p.MerchantID, Direction: "credit", Amount: net})
	}
	if fee > 0 {
		entries = append(entries, ledgerEntry{Account: "revenue:fees", Direction: "credit", Amount: fee})
	}
	return entries
}

// RecordCapture posts the capture. It is idempotent on the payment ID, so a
// retried capture never double-books.
func (c *LedgerClient) RecordCapture(ctx context.Context, p Payment) error {
	body, err := json.Marshal(ledgerTransaction{
		ExternalRef: "payment:" + p.ID.String() + ":capture",
		Currency:    p.Currency,
		Description: "card capture " + p.ID.String(),
		Entries:     CaptureEntries(p, c.FeeBps),
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/v1/transactions", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("ledger request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusCreated || resp.StatusCode == http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
	return fmt.Errorf("ledger returned %d: %s", resp.StatusCode, bytes.TrimSpace(msg))
}
