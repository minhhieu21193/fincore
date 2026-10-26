// Package payments implements payment creation with idempotency keys, a
// payment state machine, ledger posting and a transactional outbox.
package payments

import "fmt"

// Status is a payment state.
type Status string

// Payment states.
const (
	StatusPending    Status = "pending"
	StatusAuthorized Status = "authorized"
	StatusCaptured   Status = "captured"
	StatusFailed     Status = "failed"
)

// transitions is the payment state machine:
//
//	pending -> authorized -> captured
//	   |           |
//	   +--> failed <+
var transitions = map[Status][]Status{
	StatusPending:    {StatusAuthorized, StatusFailed},
	StatusAuthorized: {StatusCaptured, StatusFailed},
	StatusCaptured:   nil,
	StatusFailed:     nil,
}

// CanTransition reports whether from -> to is a legal move.
func CanTransition(from, to Status) bool {
	for _, s := range transitions[from] {
		if s == to {
			return true
		}
	}
	return false
}

// Terminal reports whether no further transitions are possible.
func (s Status) Terminal() bool {
	next, ok := transitions[s]
	return ok && len(next) == 0
}

// ErrIllegalTransition is returned when code attempts a move the state
// machine forbids.
type ErrIllegalTransition struct{ From, To Status }

func (e ErrIllegalTransition) Error() string {
	return fmt.Sprintf("illegal payment transition %s -> %s", e.From, e.To)
}
