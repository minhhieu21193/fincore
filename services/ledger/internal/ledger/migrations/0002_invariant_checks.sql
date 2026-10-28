-- Fleet-wide periodic checks: the instance that moves checked_at forward runs
-- the check, the others skip it (WatchInvariants). The imbalance check reads
-- every entry; run by every replica every few seconds, it became the
-- database's largest I/O load as the ledger grew (Phase 3 load test).
CREATE TABLE invariant_checks (
    name       text PRIMARY KEY,
    checked_at timestamptz NOT NULL DEFAULT 'epoch'
);
INSERT INTO invariant_checks (name) VALUES ('imbalance');
