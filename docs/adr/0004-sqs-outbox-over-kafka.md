# 0004. Transactional outbox to SQS, not Kafka / MSK

**Status:** accepted (Phase 1)

## Context

Every captured or failed payment must notify the merchant (a signed webhook) exactly once from their point of view, even if a pod or the queue fails between the database commit and the send. Events need no ordering across payments, and only one consumer exists today (the notifier).

## Decision

- **Transactional outbox:** the payment's state change and its event are written in the same database transaction. A relay in payments-api publishes unpublished rows in batches of 10 (`FOR UPDATE SKIP LOCKED`, so every replica can relay without double-sending) and marks them published. Delivery is at-least-once; the notifier and the merchant deduplicate on `event_id`.
- **SQS** standard queue with a dead-letter queue (redrive after `maxReceiveCount`). The notifier long-polls, delivers signed webhooks with retries, and leaves a failed message to become visible again.

## Alternatives

- **Kafka (MSK or self-managed).** It gives ordering per partition, replay and many consumers. But it costs at least three brokers around the clock, partitions and consumer groups have to be operated, and it still needs an outbox for atomicity with the database. None of its strengths are needed yet.
- **Direct publish after commit (no outbox).** A crash between the commit and the send loses the event. That's unacceptable for payment notifications.
- **SNS fan-out or EventBridge.** Worth adding when a second consumer appears. SQS stays the per-consumer buffer either way.

## Consequences

- Nothing is lost: the outbox backlog is a metric and drains after any outage (chaos evidence, `docs/evidence/phase-3/chaos.md`).
- Pay-per-request and near zero at idle (`docs/cost.md`).
- No replay of history from the queue: the outbox table and the ledger are the history.

**Revisit when** several consumers need the same stream, or event ordering per merchant becomes a requirement.
