# Ledger imbalance

**Alert:** `LedgerImbalance`: the sum of all debits minus all credits is not 0 for a currency. Page.

This should be impossible: every transaction is checked by database constraints (deferred trigger) to balance before it commits, and entries cannot be updated or deleted. An imbalance means something bypassed the ledger's code path: manual SQL, a disabled trigger, a restore that mixed two points in time, or a bug in the constraints themselves.

## Do first

1. **Stop money movement that depends on balances** (payouts, settlement jobs). Payments can keep flowing: each new transaction is still checked on its own.
2. Freeze manual access to the ledger database. Keep an audit trail of every query from now on.

## Find it

```
# The live check (one ledger replica runs it each minute; this runs it now)
kubectl -n fincore-cde port-forward svc/ledger 8081:8080 & curl -s localhost:8081/v1/invariants

# Transactions that do not balance on their own
kubectl -n fincore-data exec postgres-0 -- psql -U postgres -d ledger -c "
  select t.id, t.external_ref, t.created_at,
         sum(case e.direction when 'debit' then e.amount else -e.amount end) as diff
  from transactions t join entries e on e.transaction_id = t.id
  group by t.id having sum(case e.direction when 'debit' then e.amount else -e.amount end) <> 0
  order by t.created_at limit 20"

# Were the constraints disabled?
kubectl -n fincore-data exec postgres-0 -- psql -U postgres -d ledger -c "select tgname, tgenabled from pg_trigger where not tgisinternal"
```

Then Vault's audit log (who received database credentials when) and CloudTrail / the database logs for manual sessions.

## Fix

Never edit or delete entries. Correct with a **new, balanced transaction** that reverses the faulty one, referencing it in its description, after review by a second person. Then confirm `/v1/invariants` reports `balanced: true`, and write the postmortem.
