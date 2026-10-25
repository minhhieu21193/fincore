// Package pg builds pgx connection pools from environment variables.
package pg

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/minhhieu21193/fincore/internal/platform/config"
)

// Connect creates a pool from either DATABASE_URL or the DB_* variables
// (DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD or DB_PASSWORD_FILE,
// DB_SSLMODE).
//
// When DB_PASSWORD_FILE is used the file is re-read for every new physical
// connection, so rotated credentials (e.g. written by a secrets agent) are
// picked up without restarting the process.
func Connect(ctx context.Context) (*pgxpool.Pool, error) {
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
		user, err := config.Required("DB_USER")
		if err != nil {
			return nil, err
		}
		u := url.URL{
			Scheme:   "postgres",
			User:     url.User(user),
			Host:     net.JoinHostPort(host, config.String("DB_PORT", "5432")),
			Path:     "/" + name,
			RawQuery: "sslmode=" + config.String("DB_SSLMODE", "prefer"),
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
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute

	if pw := os.Getenv("DB_PASSWORD"); pw != "" {
		cfg.ConnConfig.Password = pw
	}
	if file := os.Getenv("DB_PASSWORD_FILE"); file != "" {
		cfg.BeforeConnect = func(_ context.Context, cc *pgx.ConnConfig) error {
			b, err := os.ReadFile(file) //nolint:gosec // path comes from trusted deployment config
			if err != nil {
				return fmt.Errorf("read DB_PASSWORD_FILE: %w", err)
			}
			cc.Password = strings.TrimSpace(string(b))
			return nil
		}
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
