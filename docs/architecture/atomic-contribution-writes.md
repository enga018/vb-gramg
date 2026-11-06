# Atomic PostgreSQL writes for individual contribution transactions

## Scope

Move the validation and insert for these existing single-job-card operations into one PostgreSQL transaction:

- Cash payment (add-payment)
- Pay in full (pay-in-full)
- Waiver (add-waiver)
- Return/refund (add-return)

The Edge Function remains responsible for verified-user authentication, approved-user lookup, and admin authorization. The browser must not call the write RPC directly. Bulk bank payment, FIFO allocation, FTO synchronization, ledger editing, extra charges, and period assignment are out of scope for this change.

## Live rules to preserve

The current Edge Function and shared calculation module establish these rules:

- Every inserted amount must be finite and greater than zero.
- Cash payment and return/waiver amount cap: ₹10,000,000. Cash payment is not currently capped by outstanding balance; do not introduce that restriction.
- Pay in full uses the current positive balance, rounded to two decimals, and rejects a zero or negative result.
- Waiver is admin-only and cannot exceed the current positive outstanding balance (existing tolerance: ₹0.001).
- Return/refund is admin-only and cannot exceed paid less prior returns (existing tolerance: ₹0.001).
- Exclude voided rows from all calculations.
- Exclude deferred charges from outstanding balance.
- Treat payment as paid; refund and legacy return as returned; and a legacy charge whose trimmed note is exactly Return as returned.
- Treat charge_waiver (and legacy forgive if present) as waived.
- Charge balance includes active non-deferred charge and other_charge; preserve the legacy sanitationFee calculation compatibility where present.
- The existing database trigger silently skips ledger writes for exempt job cards. The RPC must check vbgramg_contribution_exemptions first and return a clear rejection, never report a skipped insert as success.
- The charge ledger check constraint only permits canonical entry types: charge, payment, refund, other_charge, and charge_waiver.

## Proposed RPC contract

Create one public.vbgramg_record_contribution_transaction(...) function returning JSONB. Parameters should carry:

- job card number
- operation (cash_payment, pay_in_full, waiver, return)
- requested amount (nullable only for pay-in-full)
- entry date
- note
- actor user UUID and verified email
- actor role resolved by the Edge Function

The function should:

1. Validate operation, required values, amount cap, and date.
2. Acquire a transaction-scoped advisory lock keyed by the normalized job-card number. Every operation that reads the card balance and inserts one of these transactions must use the same lock key.
3. Reject exempt cards explicitly.
4. Load the card's person name and complete ledger state under the lock. Do not depend on the browser or JavaScript calculation module for financial authority.
5. Calculate the balance using the preserved rules above.
6. Apply operation-specific validation and determine the canonical ledger type/note:
   - cash_payment -> payment, note Cash
   - pay_in_full -> payment, note Cash, amount = rounded current positive balance
   - waiver -> charge_waiver
   - return -> refund
7. Insert the ledger row and its audit row in the same transaction. If either insert fails, the whole operation must roll back.
8. Return the inserted entry, balance before, and balance after.

Use SECURITY DEFINER only if required to insert through the existing RLS boundary. If used, set an empty search_path, schema-qualify every relation/function, and explicitly revoke EXECUTE from PUBLIC, anon, and authenticated; grant EXECUTE only to service_role. The Edge Function must continue to perform user and role authorization before invoking the RPC. Do not trust browser-supplied actor identity or role.

## Edge Function integration

Replace the read-calculate-insert sequence in the four scoped actions with one RPC call. Keep the existing verified-user and approved-role checks in the Edge Function. Map known validation failures to the same HTTP 400/403/404/409 responses and user-facing messages. Do not make a second ledger read to decide whether the write is allowed.

For cash payments, add an audit row as part of the transaction (the current add-payment path inserts the ledger row without an audit row). For pay-in-full, waiver, and return, preserve the current audit action labels: pay-in-full, waiver, and return.

## Concurrency and rollback requirements

- Two simultaneous writes for the same job card must serialize on the same advisory lock.
- Writes for different job cards should not block one another.
- Audit insertion failure must roll back the ledger insert.
- Exempt job cards must produce an explicit error and no ledger/audit rows.
- No changes to payment allocations or FIFO ordering.

## Regression matrix

| Case | Expected result |
|---|---|
| Cash amount zero, negative, NaN, or above ₹10,000,000 | Reject; no writes |
| Cash amount greater than outstanding | Accept, preserving current overpayment behaviour |
| Cash card exists only in citizen/ledger data | Match existing lookup semantics; reject only when no contribution ledger card exists |
| Pay in full with positive balance | Insert exactly rounded positive balance |
| Pay in full with zero or negative balance | Reject; no writes |
| Waiver amount positive and within balance | Insert waiver and audit atomically |
| Waiver above balance, zero, negative, or non-admin | Reject; no writes |
| Return within paid less previous returns | Insert refund and audit atomically |
| Return above eligible amount, zero, negative, or non-admin | Reject; no writes |
| Deferred-only charge | Does not increase payable balance |
| Voided charge/payment/refund/waiver | Does not affect calculated state |
| Legacy charge note exactly Return | Counts as returned, not charged |
| Exempt job card | Explicit rejection; no silent trigger skip |
| Concurrent pay-in-full / waiver against one card | Serialized; second operation sees first committed balance |
| Concurrent operations on different cards | Independent |
| Audit insert forced to fail | Ledger insert rolled back |
| Existing cash overpayment | Still allowed |
| Allocation rows on an existing payment | Not modified by this RPC |

## Verification gate

This is a design specification, not a tested migration. The user declined a paid Supabase development branch, so no isolated database environment is available. Before merging executable SQL or deploying the Edge Function, validate the function against a disposable/isolated database with the regression cases above, inspect function privileges and advisors, and verify the returned balances. No production migration or Edge Function deployment is authorized by this document.
