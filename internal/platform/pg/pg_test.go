package pg

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/minhhieu21193/fincore/internal/platform/pgtest"
)

func writeCreds(t *testing.T, path, user, password string) {
	t.Helper()
	b, err := json.Marshal(Credentials{Username: user, Password: password})
	if err != nil {
		t.Fatal(err)
	}
	// Write and rename, as Vault Agent does, so readers never see a partial file.
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

func TestReadCredentials(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.json")
	writeCreds(t, good, "v-ledger-1", "s3cret")
	c, err := ReadCredentials(good)
	if err != nil || c.Username != "v-ledger-1" || c.Password != "s3cret" {
		t.Fatalf("ReadCredentials = %+v, %v", c, err)
	}

	for name, content := range map[string]string{
		"empty password": `{"username":"u","password":""}`,
		"no username":    `{"password":"p"}`,
		"not json":       `username=u`,
	} {
		p := filepath.Join(dir, "bad.json")
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := ReadCredentials(p); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	if _, err := ReadCredentials(filepath.Join(dir, "missing.json")); err == nil {
		t.Error("missing file: expected an error")
	}
}

// TestConnectPicksUpRotatedCredentials is the property Vault-issued, short-lived
// database users rely on: when the credentials file changes, new connections use
// the new user, the old connections keep working until they are recycled, and
// the process is never restarted.
func TestConnectPicksUpRotatedCredentials(t *testing.T) {
	admin := pgtest.New(t) // skips without TEST_DATABASE_URL
	ctx := context.Background()
	var db string
	if err := admin.QueryRow(ctx, `SELECT current_database()`).Scan(&db); err != nil {
		t.Fatal(err)
	}
	suffix := time.Now().UnixNano()
	userA, userB := fmt.Sprintf("rot_a_%d", suffix), fmt.Sprintf("rot_b_%d", suffix)
	for _, u := range []string{userA, userB} {
		if _, err := admin.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s LOGIN PASSWORD 'pw-%s'`, pgx.Identifier{u}.Sanitize(), u)); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_, _ = admin.Exec(context.Background(), `DROP ROLE IF EXISTS `+pgx.Identifier{u}.Sanitize())
		})
	}

	base, err := url.Parse(os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	credFile := filepath.Join(t.TempDir(), "db.json")
	writeCreds(t, credFile, userA, "pw-"+userA)
	t.Setenv("DATABASE_URL", (&url.URL{Scheme: "postgres", Host: base.Host, Path: "/" + db, RawQuery: base.RawQuery}).String())
	t.Setenv("DB_CREDENTIALS_FILE", credFile)
	t.Setenv("DB_MAX_CONN_LIFETIME", "1h")

	pool, err := Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	currentUser := func() string {
		t.Helper()
		var u string
		if err := pool.QueryRow(ctx, `SELECT current_user`).Scan(&u); err != nil {
			t.Fatal(err)
		}
		return u
	}
	if u := currentUser(); u != userA {
		t.Fatalf("connected as %q, want %q", u, userA)
	}

	before := testutil.ToFloat64(credentialChanges)
	writeCreds(t, credFile, userB, "pw-"+userB)
	if u := currentUser(); u != userA {
		t.Fatalf("existing connection switched user to %q before being recycled", u)
	}
	pool.Reset() // what MaxConnLifetime does over time
	if u := currentUser(); u != userB {
		t.Fatalf("after rotation connected as %q, want %q", u, userB)
	}
	if got := testutil.ToFloat64(credentialChanges) - before; got != 1 {
		t.Fatalf("credential changes counted = %v, want 1", got)
	}
}
