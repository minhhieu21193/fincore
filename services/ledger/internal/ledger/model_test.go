package ledger

import (
	"bytes"
	"errors"
	"testing"
)

func validInput() TransactionInput {
	return TransactionInput{
		ExternalRef: "payment:1:capture",
		Currency:    "USD",
		Entries: []EntryInput{
			{Account: "assets:processor_receivable", Direction: Debit, Amount: 1000},
			{Account: "liabilities:merchant:m_1", Direction: Credit, Amount: 971},
			{Account: "revenue:fees", Direction: Credit, Amount: 29},
		},
	}
}

func TestValidate(t *testing.T) {
	tests := map[string]struct {
		mutate  func(*TransactionInput)
		wantErr bool
	}{
		"balanced three-leg":  {func(*TransactionInput) {}, false},
		"unbalanced":          {func(in *TransactionInput) { in.Entries[0].Amount = 999 }, true},
		"single entry":        {func(in *TransactionInput) { in.Entries = in.Entries[:1] }, true},
		"zero amount":         {func(in *TransactionInput) { in.Entries[2].Amount = 0; in.Entries[0].Amount = 971 }, true},
		"negative amount":     {func(in *TransactionInput) { in.Entries[1].Amount = -971 }, true},
		"bad direction":       {func(in *TransactionInput) { in.Entries[0].Direction = "up" }, true},
		"bad currency":        {func(in *TransactionInput) { in.Currency = "usd" }, true},
		"missing ref":         {func(in *TransactionInput) { in.ExternalRef = "" }, true},
		"unknown class":       {func(in *TransactionInput) { in.Entries[0].Account = "cash:main" }, true},
		"malformed code":      {func(in *TransactionInput) { in.Entries[0].Account = "assets" }, true},
		"overflowing amounts": {func(in *TransactionInput) { in.Entries[1].Amount = 1<<63 - 1; in.Entries[2].Amount = 1 << 62 }, true},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			in := validInput()
			tc.mutate(&in)
			err := in.Validate()
			if (err != nil) != tc.wantErr {
				t.Fatalf("Validate() error = %v, wantErr %v", err, tc.wantErr)
			}
			if err != nil && !errors.Is(err, ErrInvalid) {
				t.Fatalf("error %v does not wrap ErrInvalid", err)
			}
		})
	}
}

func TestAccountTypeFor(t *testing.T) {
	cases := map[string]AccountType{
		"assets:processor_receivable": Asset,
		"liabilities:merchant:m_1":    Liability,
		"revenue:fees":                Revenue,
		"expenses:chargebacks":        Expense,
		"equity:capital":              Equity,
	}
	for code, want := range cases {
		got, err := AccountTypeFor(code)
		if err != nil || got != want {
			t.Errorf("AccountTypeFor(%q) = %v, %v; want %v", code, got, err, want)
		}
	}
}

func TestNormalBalance(t *testing.T) {
	if got := NormalBalance(Asset, 100, 30); got != 70 {
		t.Errorf("asset balance = %d, want 70", got)
	}
	if got := NormalBalance(Liability, 30, 100); got != 70 {
		t.Errorf("liability balance = %d, want 70", got)
	}
}

func TestHashStable(t *testing.T) {
	a, b := validInput(), validInput()
	if !bytes.Equal(a.Hash(), b.Hash()) {
		t.Fatal("identical inputs must hash identically")
	}
	b.Entries[1].Amount, b.Entries[2].Amount = 970, 30
	if bytes.Equal(a.Hash(), b.Hash()) {
		t.Fatal("different inputs must hash differently")
	}
}
