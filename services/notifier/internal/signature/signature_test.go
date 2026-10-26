package signature

import (
	"errors"
	"testing"
	"time"
)

func TestSignVerify(t *testing.T) {
	secret := []byte("s3cr3t")
	body := []byte(`{"event_id":"e1"}`)
	now := time.Unix(1_800_000_000, 0)
	h := Sign(secret, body, now)

	if err := Verify(secret, body, h, now.Add(10*time.Second), 5*time.Minute); err != nil {
		t.Fatalf("valid signature rejected: %v", err)
	}
	cases := map[string]struct {
		secret, body []byte
		header       string
		at           time.Time
		want         error
	}{
		"tampered body": {secret, []byte(`{"event_id":"e2"}`), h, now, ErrMismatch},
		"wrong secret":  {[]byte("other"), body, h, now, ErrMismatch},
		"too old":       {secret, body, h, now.Add(10 * time.Minute), ErrExpired},
		"from future":   {secret, body, h, now.Add(-10 * time.Minute), ErrExpired},
		"garbage":       {secret, body, "nonsense", now, ErrMalformed},
		"missing v1":    {secret, body, "t=1800000000", now, ErrMalformed},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			if err := Verify(c.secret, c.body, c.header, c.at, 5*time.Minute); !errors.Is(err, c.want) {
				t.Fatalf("Verify() = %v, want %v", err, c.want)
			}
		})
	}
}
