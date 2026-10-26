CREATE TABLE payments (
    id             uuid        PRIMARY KEY,
    merchant_id    text        NOT NULL,
    amount         bigint      NOT NULL CHECK (amount > 0),
    currency       char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    status         text        NOT NULL CHECK (status IN ('pending', 'authorized', 'captured', 'failed')),
    failure_reason text,
    processor_ref  text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX payments_merchant_created_idx ON payments (merchant_id, created_at DESC);

-- State machine, enforced by the database as a second line of defence:
--   pending -> authorized | failed
--   authorized -> captured | failed
--   captured, failed: terminal
CREATE FUNCTION payments_guard_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status = 'pending'    AND NEW.status IN ('authorized', 'failed'))
    OR (OLD.status = 'authorized' AND NEW.status IN ('captured', 'failed')) THEN
        NEW.updated_at := now();
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'illegal payment transition % -> % for %', OLD.status, NEW.status, OLD.id
        USING ERRCODE = 'check_violation';
END;
$$;

CREATE TRIGGER payments_state_machine
    BEFORE UPDATE OF status ON payments
    FOR EACH ROW EXECUTE FUNCTION payments_guard_transition();

-- Idempotency keys are scoped per merchant. The stored response is replayed
-- verbatim for retries; locked_at marks a request that is still in flight.
CREATE TABLE idempotency_keys (
    merchant_id     text        NOT NULL,
    key             text        NOT NULL CHECK (length(key) BETWEEN 1 AND 255),
    request_hash    bytea       NOT NULL,
    payment_id      uuid        NOT NULL REFERENCES payments (id),
    response_status int,
    response_body   bytea,          -- exact bytes, replayed verbatim
    locked_at       timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (merchant_id, key)
);

-- Transactional outbox: rows are written in the same transaction as the
-- state change they describe, then relayed to SQS by a background worker.
CREATE TABLE outbox (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id     uuid        NOT NULL UNIQUE,
    aggregate_id uuid        NOT NULL,
    event_type   text        NOT NULL,
    payload      jsonb       NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    attempts     int         NOT NULL DEFAULT 0
);

CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;
