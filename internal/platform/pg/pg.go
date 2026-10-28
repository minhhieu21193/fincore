// Package pg builds pgx connection pools from environment variables.
package pg

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	"github.com/minhhieu21193/fincore/internal/platform/config"
	"github.com/minhhieu21193/fincore/internal/platform/httpx"
)

var credentialChanges = promauto.With(httpx.Registry).NewCounter(prometheus.CounterOpts{
	Name: "fincore_db_credential_changes_total",
	Help: "Times the database credentials file changed user (rotation by the secrets agent).",
})

// Connect creates a pool from either DATABASE_URL or the DB_* variables
// (DB_HOST, DB_PORT, DB_NAME, DB_SSLMODE and one way to authenticate).
//
// Credentials, in order of precedence:
//   - DB_CREDENTIALS_FILE: JSON {"username": "...", "password": "..."}, e.g.
//     rendered by Vault Agent from a dynamic database secret;
//   - DB_USER with DB_PASSWORD_FILE;
//   - DB_USER with DB_PASSWORD.
//
// Files are re-read for every new physical connection, so rotated credentials
// are picked up without restarting the process. DB_MAX_CONN_LIFETIME bounds how
// long a connection keeps using the credentials it was opened with; keep it well
// below the credentials' remaining lifetime when they are rotated.
func Connect(ctx context.Context) (*pgxpool.Pool, error) {
	cfg, err := poolConfig()
	if err != nil {
		return nil, err
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	// Wait for the database: on a fresh cluster it may start after the app.
	deadline := time.Now().Add(2 * time.Minute)
	for {
		pctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = pool.Ping(pctx)
		cancel()
		if err == nil {
			return pool, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			pool.Close()
			return nil, fmt.Errorf("database not reachable: %w", err)
		}
		slog.Warn("waiting for database", "error", err)
		time.Sleep(2 * time.Second)
	}
}

// poolConfig builds the pool configuration from the environment.
func poolConfig() (*pgxpool.Config, error) {
	credFile := os.Getenv("DB_CREDENTIALS_FILE")
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		host, err := config.Required("DB_HOST")
		if err != nil {
			return nil, err
		}
		name, err := config.Required("DB_NAME")
		if err != nil {
			return nil, err
		}
		u := url.URL{
			Scheme:   "postgres",
			Host:     net.JoinHostPort(host, config.String("DB_PORT", "5432")),
			Path:     "/" + name,
			RawQuery: "sslmode=" + config.String("DB_SSLMODE", "prefer"),
		}
		if credFile == "" {
			user, err := config.Required("DB_USER")
			if err != nil {
				return nil, err
			}
			u.User = url.User(user)
		}
		dsn = u.String()
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse database config: %w", err)
	}
	maxConns, err := config.Int("DB_MAX_CONNS", 10)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = int32(maxConns) //nolint:gosec // bounded by operator config
	if cfg.MaxConnLifetime, err = config.Duration("DB_MAX_CONN_LIFETIME", 30*time.Minute); err != nil {
		return nil, err
	}
	cfg.MaxConnLifetimeJitter = cfg.MaxConnLifetime / 10
	cfg.MaxConnIdleTime = min(5*time.Minute, cfg.MaxConnLifetime)
	if cfg.HealthCheckPeriod, err = config.Duration("DB_HEALTH_CHECK_PERIOD", time.Minute); err != nil {
		return nil, err
	}
	// Bound every new connection (dial, TLS, startup). Without it, a dial to a
	// database address that just went away (a restart or failover) waits out
	// the kernel's SYN retries, about 2 minutes, while holding one of the
	// pool's slots: after a 6 s database restart, every slot was stuck and
	// payments failed for 2 minutes (Phase 3 chaos test).
	if cfg.ConnConfig.ConnectTimeout, err = config.Duration("DB_CONNECT_TIMEOUT", 5*time.Second); err != nil {
		return nil, err
	}

	if pw := os.Getenv("DB_PASSWORD"); pw != "" {
		cfg.ConnConfig.Password = pw
	}
	switch {
	case credFile != "":
		src := &credentialsFile{path: credFile}
		cfg.BeforeConnect = func(_ context.Context, cc *pgx.ConnConfig) error { return src.apply(cc) }
	case os.Getenv("DB_PASSWORD_FILE") != "":
		file := os.Getenv("DB_PASSWORD_FILE")
		cfg.BeforeConnect = func(_ context.Context, cc *pgx.ConnConfig) error {
			b, err := os.ReadFile(file) //nolint:gosec // path comes from trusted deployment config
			if err != nil {
				return fmt.Errorf("read DB_PASSWORD_FILE: %w", err)
			}
			cc.Password = strings.TrimSpace(string(b))
			return nil
		}
	}

	return cfg, nil
}

// Credentials is the content of DB_CREDENTIALS_FILE.
type Credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// ReadCredentials reads and validates a credentials file.
func ReadCredentials(path string) (Credentials, error) {
	var c Credentials
	b, err := os.ReadFile(path) //nolint:gosec // path comes from trusted deployment config
	if err != nil {
		return c, fmt.Errorf("read DB_CREDENTIALS_FILE: %w", err)
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, fmt.Errorf("parse DB_CREDENTIALS_FILE: %w", err)
	}
	if c.Username == "" || c.Password == "" {
		return c, errors.New("DB_CREDENTIALS_FILE: username and password are required")
	}
	return c, nil
}

// credentialsFile applies the current file content to each new connection and
// reports when the user changes. The password is never logged.
type credentialsFile struct {
	path string
	mu   sync.Mutex
	user string
}

func (f *credentialsFile) apply(cc *pgx.ConnConfig) error {
	c, err := ReadCredentials(f.path)
	if err != nil {
		return err
	}
	cc.User, cc.Password = c.Username, c.Password

	f.mu.Lock()
	defer f.mu.Unlock()
	if f.user != c.Username {
		if f.user == "" {
			slog.Info("database credentials loaded", "db_user", c.Username)
		} else {
			slog.Info("database credentials rotated", "previous_db_user", f.user, "db_user", c.Username)
			credentialChanges.Inc()
		}
		f.user = c.Username
	}
	return nil
}
