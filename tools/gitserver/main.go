// Command gitserver serves git repositories read-only over the smart HTTP
// protocol, so Argo CD running inside kind can sync from the developer's
// local repository (bind-mounted into the node) without any remote.
//
// Only fetch/clone (git-upload-pack) is supported; pushes are rejected.
// It is a local-development tool and is never deployed to AWS.
package main

import (
	"compress/gzip"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var repoName = regexp.MustCompile(`^/([A-Za-z0-9_.-]+\.git)/(info/refs|git-upload-pack)$`)

func main() {
	root := os.Getenv("GIT_PROJECT_ROOT")
	if root == "" {
		root = "/repos"
	}
	addr := os.Getenv("HTTP_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	srv := &http.Server{
		Addr:              addr,
		Handler:           handler(root),
		ReadHeaderTimeout: 10 * time.Second,
	}
	slog.Info("serving git repositories", "root", root, "addr", addr)
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func handler(root string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			return
		}
		m := repoName.FindStringSubmatch(r.URL.Path)
		if m == nil {
			http.NotFound(w, r)
			return
		}
		// The regexp admits no path separators; reject ".." explicitly too.
		if strings.Contains(m[1], "..") {
			http.NotFound(w, r)
			return
		}
		repo := filepath.Join(root, m[1])
		if _, err := os.Stat(repo); err != nil { //nolint:gosec // name validated above, joined under a fixed root
			http.NotFound(w, r)
			return
		}
		env := append(os.Environ(), "GIT_PROTOCOL="+r.Header.Get("Git-Protocol"))

		switch {
		case m[2] == "info/refs" && r.Method == http.MethodGet:
			if r.URL.Query().Get("service") != "git-upload-pack" {
				http.Error(w, "only git-upload-pack is supported (read-only)", http.StatusForbidden)
				return
			}
			w.Header().Set("Content-Type", "application/x-git-upload-pack-advertisement")
			w.Header().Set("Cache-Control", "no-cache")
			// Protocol v2 clients do not expect the service announcement.
			if !strings.Contains(r.Header.Get("Git-Protocol"), "version=2") {
				_, _ = io.WriteString(w, pktLine("# service=git-upload-pack\n")+"0000")
			}
			run(w, r, env, nil, "upload-pack", "--stateless-rpc", "--advertise-refs", repo)
		case m[2] == "git-upload-pack" && r.Method == http.MethodPost:
			body := io.Reader(r.Body)
			if r.Header.Get("Content-Encoding") == "gzip" {
				gz, err := gzip.NewReader(r.Body)
				if err != nil {
					http.Error(w, err.Error(), http.StatusBadRequest)
					return
				}
				defer func() { _ = gz.Close() }()
				body = gz
			}
			w.Header().Set("Content-Type", "application/x-git-upload-pack-result")
			w.Header().Set("Cache-Control", "no-cache")
			run(w, r, env, body, "upload-pack", "--stateless-rpc", repo)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
}

func run(w http.ResponseWriter, r *http.Request, env []string, stdin io.Reader, args ...string) {
	cmd := exec.CommandContext(r.Context(), "git", args...) //nolint:gosec // fixed binary, repo path validated by regexp
	cmd.Env = env
	cmd.Stdin = stdin
	cmd.Stdout = w
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		slog.Error("git command failed", "args", args, "error", err, "stderr", stderr.String())
	}
}

func pktLine(s string) string {
	return fmt.Sprintf("%04x%s", len(s)+4, s)
}
