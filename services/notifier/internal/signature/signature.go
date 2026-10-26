// Package signature signs and verifies webhook payloads.
//
// Header format (modelled on common PSP schemes):
//
//	FinCore-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>
//
// Including the timestamp in the MAC lets receivers reject replays older than
// a tolerance window.
package signature

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"
)

// Header is the HTTP header carrying the signature.
const Header = "FinCore-Signature"

// Errors returned by Verify.
var (
	ErrMalformed = errors.New("malformed signature header")
	ErrMismatch  = errors.New("signature mismatch")
	ErrExpired   = errors.New("signature timestamp outside tolerance")
)

// Sign returns the header value for body at time t.
func Sign(secret []byte, body []byte, t time.Time) string {
	ts := strconv.FormatInt(t.Unix(), 10)
	return "t=" + ts + ",v1=" + mac(secret, ts, body)
}

// Verify checks header against body. tolerance bounds the clock skew/replay window.
func Verify(secret []byte, body []byte, header string, now time.Time, tolerance time.Duration) error {
	var ts, sig string
	for part := range strings.SplitSeq(header, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			return ErrMalformed
		}
		switch k {
		case "t":
			ts = v
		case "v1":
			sig = v
		}
	}
	if ts == "" || sig == "" {
		return ErrMalformed
	}
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return ErrMalformed
	}
	if d := now.Sub(time.Unix(sec, 0)); d > tolerance || d < -tolerance {
		return ErrExpired
	}
	want, err := hex.DecodeString(mac(secret, ts, body))
	if err != nil {
		return err
	}
	got, err := hex.DecodeString(sig)
	if err != nil {
		return ErrMalformed
	}
	if !hmac.Equal(want, got) {
		return ErrMismatch
	}
	return nil
}

func mac(secret []byte, ts string, body []byte) string {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(ts))
	m.Write([]byte("."))
	m.Write(body)
	return hex.EncodeToString(m.Sum(nil))
}
