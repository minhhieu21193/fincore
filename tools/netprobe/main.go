// Command netprobe attempts TCP connections and reports, one line per target,
// whether each was OPEN, BLOCKED (no answer: dropped by a NetworkPolicy) or
// REFUSED. It is the evidence tool of the NetworkPolicy demo and ships as a
// signed, distroless, non-root image so it passes the same admission policies
// as the services.
//
//	netprobe [-timeout 3s] [-delay 0s] name=host:port ...
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
)

func main() {
	timeout := flag.Duration("timeout", 3*time.Second, "connect timeout per target")
	delay := flag.Duration("delay", 0, "wait before probing (lets the network policy engine see a new pod)")
	flag.Parse()
	if flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: netprobe [-timeout 3s] [-delay 0s] name=host:port ...")
		os.Exit(2)
	}
	time.Sleep(*delay)
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

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}
