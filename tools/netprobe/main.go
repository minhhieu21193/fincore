// Command netprobe attempts TCP connections and reports, one line per target,
// whether each was OPEN, BLOCKED (no answer: dropped by a NetworkPolicy) or
// REFUSED. It is the evidence tool of the NetworkPolicy demo and ships as a
// signed, distroless, non-root image so it passes the same admission policies
// as the services.
//
//	netprobe [-timeout 3s] [-delay 0s] name=host:port ...
//	netprobe -repeat 600 -every 100ms name=host:port   # connect-latency distribution
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"syscall"
	"time"
)

func main() {
	timeout := flag.Duration("timeout", 3*time.Second, "connect timeout per target")
	delay := flag.Duration("delay", 0, "wait before probing (lets the network policy engine see a new pod)")
	repeat := flag.Int("repeat", 1, "connections per target; above 1, print the connect-latency distribution")
	every := flag.Duration("every", 100*time.Millisecond, "pause between repeated connections")
	flag.Parse()
	if flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: netprobe [-timeout 3s] [-delay 0s] name=host:port ...")
		os.Exit(2)
	}
	time.Sleep(*delay)
	if *repeat > 1 {
		for _, arg := range flag.Args() {
			_, addr, ok := strings.Cut(arg, "=")
			if !ok {
				addr = arg
			}
			latency(addr, *repeat, *every, *timeout)
		}
		return
	}
	for _, arg := range flag.Args() {
		name, addr, ok := strings.Cut(arg, "=")
		if !ok {
			name, addr = arg, arg
		}
		fmt.Printf("%-28s %-52s %s\n", name, addr, probe(addr, *timeout))
	}
}

func probe(addr string, timeout time.Duration) string {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", addr)
	switch {
	case err == nil:
		_ = conn.Close()
		return "OPEN"
	case errors.Is(err, context.DeadlineExceeded) || isTimeout(err):
		return fmt.Sprintf("BLOCKED (no answer within %s)", timeout)
	case errors.Is(err, syscall.ECONNREFUSED):
		return "REFUSED"
	default:
		var dnsErr *net.DNSError
		if errors.As(err, &dnsErr) {
			return "DNS-ERROR (" + dnsErr.Err + ")"
		}
		return "ERROR (" + err.Error() + ")"
	}
}

// latency connects n times and prints percentiles and the slowest connects.
func latency(addr string, n int, every, timeout time.Duration) {
	type sample struct {
		at time.Time
		d  time.Duration
	}
	var samples []sample
	failed := 0
	for range n {
		start := time.Now()
		conn, err := net.DialTimeout("tcp", addr, timeout)
		if err != nil {
			failed++
		} else {
			_ = conn.Close()
			samples = append(samples, sample{start, time.Since(start)})
		}
		time.Sleep(every)
	}
	sorted := append([]sample(nil), samples...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].d < sorted[j].d })
	pct := func(p float64) time.Duration {
		if len(sorted) == 0 {
			return 0
		}
		return sorted[int(p*float64(len(sorted)-1))].d
	}
	fmt.Printf("%s: %d connects, %d failed, p50=%s p99=%s max=%s\n", addr, len(samples), failed,
		pct(0.50).Round(time.Microsecond), pct(0.99).Round(time.Microsecond), pct(1).Round(time.Microsecond))
	for _, s := range sorted[max(0, len(sorted)-5):] {
		fmt.Printf("  slow: %s at %s\n", s.d.Round(time.Microsecond), s.at.UTC().Format("15:04:05.000"))
	}
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}
