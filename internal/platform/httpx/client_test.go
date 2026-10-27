package httpx

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// A keep-alive pool must not stay pinned to the endpoints it first reached:
// after the recycle interval, requests open new connections (which kube-proxy
// spreads over the current pods, including a canary).
func TestRecyclingTransportOpensNewConnections(t *testing.T) {
	var conns atomic.Int64
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	srv.Config.ConnState = func(_ net.Conn, s http.ConnState) {
		if s == http.StateNew {
			conns.Add(1)
		}
	}
	srv.Start()
	defer srv.Close()

	base := http.DefaultTransport.(*http.Transport).Clone()
	client := &http.Client{Transport: newRecyclingTransport(base, 50*time.Millisecond)}
	get := func() {
		t.Helper()
		resp, err := client.Get(srv.URL)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}

	for range 5 {
		get()
	}
	if got := conns.Load(); got != 1 {
		t.Fatalf("within the interval the connection should be reused: %d connections", got)
	}
	time.Sleep(60 * time.Millisecond)
	get()
	if got := conns.Load(); got != 2 {
		t.Fatalf("after the interval a new connection should be opened: %d connections", got)
	}
}
