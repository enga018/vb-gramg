# Atomic PostgreSQL writes for individual contribution transactions

## Scope

Move validation and insertion for these single-job-card operations into one PostgreSQL transaction:

- Cash payment (add-payment)
- Pay in full (pay-in-full)
- Waiver (add-waiver)
- Return/refund (add-return)

The Edge Function remains responsible for verified-user authentication, approved-user lookup, and admin authorization. The browser must not call the write RPC directly. Bulk bank payment, FIFO allocation, FTO synchronization, ledger editing, extra charges, and period assignment are out of scope.

## Existing rules to preserve

Observed in the current Edge Function and shared calculation module:

- All four operations require a finite positive amount at insertion.
- Cash payment has a maximum of ₹10,000,000 and requires at least one existing ledger row with entry_type = charge for that job card. It is not capped by outstanding balance; preserve the current overpayment behaviour.
- Pay in full calculates the current balance in JavaScript, rounds to two decimals, and rejects zero or negative balance.
- Waiver is admin-only, positive, and cannot exceed current outstanding balance (existing tolerance: ₹0.001). There is no separate ₹10,000,000 cap in the current waiver action.
- Return/refund is admin-only, positive, and cannot exceed paid less previous returns (existing tolerance: ₹0.001). There is no separate ₹10,000,000 cap in the current return action.
- Exclude voided rows from calculations.
- Exclude deferred charges from outstanding balance.
- Treat payment as paid; refund and legacy return as returned; and a legacy charge whose trimmed note is exactly Return as returned.
- Treat charge_waiver (and legacy forgive if present in imported history) as waived.
- The live financial summary includes active non-deferred charge, other_charge, and legacy sanitationFee in charges; the live canonical ledger constraint allows only charge, payment, refund, other_charge, and charge_waiver. New writes must use canonical types.
- The existing database trigger silently skips ledger writes for exempt job cards. The RPC must check vbgramg_contribution_exemptions first and return an explicit rejection; it must never report a skipped insert as success.
- Cash payment currently inserts no audit row. Pay-in-full, waiver, and return insert audit rows with action labels pay-in-full, waiver, and return.

## Proposed RPC contract

Create one public.vbgramg_record_contribution_transaction(...) function returning JSONB. Parameters should include:

- job card number
- operation: cash_payment, pay_in_full, waiver, or return
- requested amount (nullable only for pay-in-full)
- entry date
- note
- actor user UUID and verified email
- a server-derived admin flag only if needed for database-level defense (never browser supplied)

The function should:

1. Validate the operation, required values, date, and amount positivity.
2. Apply the ₹10,000,000 maximum only to cash_payment, matching current behaviour.
3. Acquire a transaction-scoped advisory lock keyed by the normalized job-card number. All four operations must use the same lock key.
4. Reject exempt cards explicitly.
5. For cash_payment, require an existing charge ledger row for that job card, matching the current add-payment lookup.
6. Load the person name and ledger state under the lock. Financial authority must reside in PostgreSQL, not browser JavaScript.
7. Calculate balance preserving the current semantics: exclude voided rows; exclude deferred charge rows; count active payments, waivers, refunds/returns and legacy Return charges correctly. Preserve the current waiver allocation/capping semantics.
8. Apply operation-specific rules and canonical ledger values:
   - cash_payment -> payment, note Cash; positive amount <= ₹10,000,000; overpayment remains allowed.
   - pay_in_full -> payment, note Cash; amount = rounded positive current balance; reject if <= 0.
   - waiver -> charge_waiver; admin only; amount <= positive current balance + existing 0.001 tolerance.
   - return -> refund; admin only; amount <= paid less previous returns + existing 0.001 tolerance.
9. Insert the ledger row and audit row in the same transaction. Any failure must roll back both.
10. Return the inserted entry, balance before, and balance after.

Use SECURITY DEFINER only if required to write through the existing RLS boundary. If used, set an empty search_path, schema-qualify every relation/function, revoke EXECUTE from PUBLIC, anon, and authenticated, and grant EXECUTE only to service_role. The Edge Function must authenticate and authorize before calling the RPC. Never trust browser-supplied actor identity or role.

## Edge Function integration

Replace the read-calculate-insert sequence in the four scoped actions with one RPC call. Keep verified-user and approved-role checks in the Edge Function. Preserve existing response status/message behaviour for validation failures. Do not perform a second ledger read to decide whether the write is allowed.

Add cash-payment audit atomically, using an action label agreed for audit consistency (suggested: cash-payment). Preserve existing audit action labels for pay-in-full, waiver, and return.

## Concurrency and rollback requirements

- Two simultaneous writes for the same job card serialize on the same advisory lock.
- Writes for different job cards should not block one another.
- Audit insertion failure rolls back the ledger insert.
- Exempt cards return a clear error and create no ledger/audit rows.
- Do not modify payment allocations or FIFO ordering.

## Regression matrix

| Case | Expected result |
|---|---|
| Cash amount zero, negative, non-finite, or above ₹10,000,000 | Reject; no writes |
| Cash card has no existing charge ledger row | Reject; no writes |
| Cash amount greater than outstanding | Accept, preserving current behaviour |
| Pay in full with positive balance | Insert exactly rounded positive balance |
| Pay in full with zero or negative balance | Reject; no writes |
| Waiver positive and within balance | Insert waiver and audit atomically |
| Waiver above balance, zero, negative, or non-admin | Reject; no writes |
| Return within paid less previous returns | Insert refund and audit atomically |
| Return above eligible amount, zero, negative, or non-admin | Reject; no writes |
| Deferred-only charge | Does not increase payable balance |
| Voided charge/payment/refund/waiver | Does not affect calculated state |
| Legacy charge note exactly Return | Counts as returned, not charged |
| Exempt job card | Explicit rejection; no silent trigger skip |
| Concurrent pay-in-full / waiver on one card | Serialized; second operation sees committed first result |
| Concurrent operations on different cards | Independent |
| Audit insert forced to fail | Ledger insert rolled back |
| Existing cash overpayment | Still allowed |
| Existing payment allocations | Not modified |

## Verification gate

This is a design specification, not a tested migration. The user declined a paid Supabase development branch, so there is no isolated Supabase database available for safe execution testing. Before merging executable SQL or deploying the Edge Function, validate the function against a disposable/isolated database with the regression cases above, inspect privileges and advisors, and verify returned balances. No production migration or Edge Function deployment is authorized by this document.
