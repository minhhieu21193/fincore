-- Double-entry ledger.
--
-- Invariants enforced by the database itself (not only by application code):
--   1. Every transaction has >= 2 entries and sum(debits) = sum(credits)
--      (deferred constraint triggers, checked at COMMIT).
--   2. All entries of a transaction share one currency, matching each account.
--   3. Entries and transactions are append-only (no UPDATE / DELETE).
--   4. There is no stored balance column: balances are always SUM(entries).

CREATE TABLE accounts (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code       text        NOT NULL UNIQUE CHECK (code ~ '^[a-z_]+(:[A-Za-z0-9_.-]+)+$'),
    type       text        NOT NULL CHECK (type IN ('asset', 'liability', 'equity', 'revenue', 'expense')),
    currency   char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE transactions (
    id           uuid        PRIMARY KEY,
    external_ref text        NOT NULL UNIQUE,
    description  text        NOT NULL DEFAULT '',
    currency     char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    request_hash bytea       NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE entries (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id uuid        NOT NULL REFERENCES transactions (id),
    account_id     bigint      NOT NULL REFERENCES accounts (id),
    direction      text        NOT NULL CHECK (direction IN ('debit', 'credit')),
    amount         bigint      NOT NULL CHECK (amount > 0),
    currency       char(3)     NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX entries_account_id_idx ON entries (account_id);
CREATE INDEX entries_transaction_id_idx ON entries (transaction_id);

-- Invariants 1 + 2, evaluated once per transaction at COMMIT time.
CREATE FUNCTION ledger_assert_balanced(tx_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    debits     bigint;
    credits    bigint;
    n_entries  int;
    n_bad_ccy  int;
BEGIN
    SELECT coalesce(sum(e.amount) FILTER (WHERE e.direction = 'debit'), 0),
           coalesce(sum(e.amount) FILTER (WHERE e.direction = 'credit'), 0),
           count(*),
           count(*) FILTER (WHERE e.currency <> t.currency OR a.currency <> t.currency)
      INTO debits, credits, n_entries, n_bad_ccy
      FROM transactions t
      LEFT JOIN entries e ON e.transaction_id = t.id
      LEFT JOIN accounts a ON a.id = e.account_id
     WHERE t.id = tx_id;

    IF n_entries < 2 THEN
        RAISE EXCEPTION 'ledger transaction % has % entries; at least 2 required', tx_id, n_entries
            USING ERRCODE = 'check_violation';
    END IF;
    IF debits <> credits THEN
        RAISE EXCEPTION 'ledger transaction % is unbalanced: debits=% credits=%', tx_id, debits, credits
            USING ERRCODE = 'check_violation';
    END IF;
    IF n_bad_ccy > 0 THEN
        RAISE EXCEPTION 'ledger transaction % mixes currencies', tx_id
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$;

CREATE FUNCTION ledger_check_entry() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM ledger_assert_balanced(NEW.transaction_id);
    RETURN NULL;
END;
$$;

CREATE FUNCTION ledger_check_transaction() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM ledger_assert_balanced(NEW.id);
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER entries_balanced
    AFTER INSERT ON entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger_check_entry();

-- Catches a transaction row committed with no entries at all.
CREATE CONSTRAINT TRIGGER transactions_balanced
    AFTER INSERT ON transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger_check_transaction();

-- Invariant 3.
CREATE FUNCTION ledger_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'ledger table % is append-only', TG_TABLE_NAME
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

CREATE TRIGGER entries_append_only
    BEFORE UPDATE OR DELETE ON entries
    FOR EACH ROW EXECUTE FUNCTION ledger_append_only();

CREATE TRIGGER transactions_append_only
    BEFORE UPDATE OR DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION ledger_append_only();

CREATE TRIGGER entries_no_truncate
    BEFORE TRUNCATE ON entries
    FOR EACH STATEMENT EXECUTE FUNCTION ledger_append_only();

CREATE TRIGGER transactions_no_truncate
    BEFORE TRUNCATE ON transactions
    FOR EACH STATEMENT EXECUTE FUNCTION ledger_append_only();
