package httpx

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func readyz(t *testing.T, mux *http.ServeMux) int {
	t.Helper()
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	return rec.Code
}

// The dependency check gates the first readiness only; afterwards a failing
// dependency no longer takes the instance out of the Service.
func TestReadinessChecksDependencyUntilFirstSuccess(t *testing.T) {
	var fail bool
	calls := 0
	rd := NewReadiness(func(context.Context) error {
		calls++
		if fail {
			return errors.New("database unreachable")
		}
		return nil
	})
	mux := http.NewServeMux()
	rd.Register(mux)

	fail = true
	if got := readyz(t, mux); got != http.StatusServiceUnavailable {
		t.Fatalf("before the dependency is reached: got %d, want 503", got)
	}
	fail = false
	if got := readyz(t, mux); got != http.StatusOK {
		t.Fatalf("once the dependency is reached: got %d, want 200", got)
	}
	fail = true
	if got := readyz(t, mux); got != http.StatusOK {
		t.Fatalf("after a later dependency failure: got %d, want 200", got)
	}
	if calls != 2 {
		t.Fatalf("dependency checked %d times, want 2 (not after the first success)", calls)
	}
}

func TestReadinessFailsWhenShuttingDown(t *testing.T) {
	rd := NewReadiness(nil)
	mux := http.NewServeMux()
	rd.Register(mux)
	if got := readyz(t, mux); got != http.StatusOK {
		t.Fatalf("got %d, want 200", got)
	}
	rd.shuttingDown.Store(true)
	if got := readyz(t, mux); got != http.StatusServiceUnavailable {
		t.Fatalf("while shutting down: got %d, want 503", got)
	}
}
