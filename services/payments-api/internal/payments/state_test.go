package payments

import "testing"

func TestStateMachine(t *testing.T) {
	all := []Status{StatusPending, StatusAuthorized, StatusCaptured, StatusFailed}
	legal := map[[2]Status]bool{
		{StatusPending, StatusAuthorized}:  true,
		{StatusPending, StatusFailed}:      true,
		{StatusAuthorized, StatusCaptured}: true,
		{StatusAuthorized, StatusFailed}:   true,
	}
	for _, from := range all {
		for _, to := range all {
			if got := CanTransition(from, to); got != legal[[2]Status{from, to}] {
				t.Errorf("CanTransition(%s, %s) = %v, want %v", from, to, got, !got)
			}
		}
	}
	for s, terminal := range map[Status]bool{StatusPending: false, StatusAuthorized: false, StatusCaptured: true, StatusFailed: true} {
		if s.Terminal() != terminal {
			t.Errorf("%s.Terminal() = %v, want %v", s, !terminal, terminal)
		}
	}
}

func TestCaptureEntriesAlwaysBalance(t *testing.T) {
	for _, amount := range []int64{1, 33, 99, 100, 1000, 12345, 99_999_999} {
		for _, bps := range []int64{0, 1, 290, 10_000} {
			var debits, credits int64
			for _, e := range CaptureEntries(Payment{Amount: amount, MerchantID: "m"}, bps) {
				if e.Amount <= 0 {
					t.Fatalf("amount=%d bps=%d: non-positive leg %+v", amount, bps, e)
				}
				if e.Direction == "debit" {
					debits += e.Amount
				} else {
					credits += e.Amount
				}
			}
			if debits != credits {
				t.Errorf("amount=%d bps=%d: debits %d != credits %d", amount, bps, debits, credits)
			}
		}
	}
}

func TestCreateRequestValidate(t *testing.T) {
	ok := CreateRequest{MerchantID: "m_1", Amount: 1000, Currency: "USD", CardToken: "tok_visa"}
	if err := ok.Validate(); err != nil {
		t.Fatalf("valid request rejected: %v", err)
	}
	bad := []CreateRequest{
		{MerchantID: "", Amount: 1000, Currency: "USD", CardToken: "tok_visa"},
		{MerchantID: "m 1", Amount: 1000, Currency: "USD", CardToken: "tok_visa"},
		{MerchantID: "m_1", Amount: 0, Currency: "USD", CardToken: "tok_visa"},
		{MerchantID: "m_1", Amount: -5, Currency: "USD", CardToken: "tok_visa"},
		{MerchantID: "m_1", Amount: 1000, Currency: "usd", CardToken: "tok_visa"},
		{MerchantID: "m_1", Amount: 1000, Currency: "USD", CardToken: ""},
	}
	for _, r := range bad {
		if r.Validate() == nil {
			t.Errorf("invalid request accepted: %+v", r)
		}
	}
}
