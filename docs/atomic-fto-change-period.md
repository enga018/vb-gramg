# Atomic FTO Change Period — implementation plan

> Status: implementation committed to PR #224 for CI and review. No production migration or Edge Function deployment has been performed.

## Problem

The `change-fto-period` action in `supabase/functions/vbgramg-contribution-data/index.ts` currently performs a period reassignment as a sequence of independent PostgREST requests. It updates the batch first, then recalculates affected transactions and ledger rows, and finally changes transaction-to-ledger links.

A failure partway through can leave the batch, charge ledger, and transaction links inconsistent. The current path also physically deletes duplicate or no-longer-needed FTO charge ledger rows, which is not appropriate for an auditable financial ledger.

## Target design

Move the complete reassignment into one PostgreSQL RPC invoked once by the Edge Function. PostgreSQL must own the transaction boundary and perform all validation, locking, recalculation, ledger changes, and link updates atomically.

### Required transaction behavior

1. Validate the batch, destination period, month label, and period status inside the RPC. Edge Function pre-reads are not authoritative.
2. Read the batch to discover its cards, acquire the shared transaction-scoped advisory lock for every affected card using `contribution-card:<job-card-number>`, then lock and re-read the batch. This matches snapshot lock order and avoids a batch-row/card-lock deadlock.
3. Acquire card locks in lexical order to avoid deadlocks.
4. Re-read all transactions and relevant batches/periods after locks are acquired. Determine all old and new contribution rounds that must be recalculated.
5. Re-evaluate immutable first-seen eligibility inside the transaction using each FTO transaction's `created_at` and `vbgramg_contribution_exemption_history` intervals. A transaction first seen during an exemption interval remains ineligible even if the exemption later ends. Do not substitute the current active-exemption list for interval history.
6. Preserve the existing FTO charge formula and stored transaction `calculated_charge` values. This workflow changes period assignment, not calculation parameters.
7. Rebuild only the FTO charge component for affected card/round pairs. Preserve manual charges and FTO EXTRA charges as independent ledger entries.
8. Never modify payment ledger rows or `vbgramg_payment_allocations`.
9. Do not physically delete ledger rows. Retain superseded FTO charge rows for audit and mark them voided using the existing `is_voided` lifecycle field. Create a replacement aggregate for each affected card/round; never automatically unvoid an older row.
10. Update batch period fields, ledger charge period/period ID, and affected transaction `ledger_entry_id` links in the same database transaction.
11. Any validation, allocation-safety, uniqueness, or write failure must roll back every change.
12. Return a compact result with batch ID, old/new period, transaction count, affected card count, and ledger rows created/updated/voided.

## Financial safeguards

- Do not change the FTO charge formula, multiplier/divisor, or historical transaction charge values.
- Do not change payment allocations or payment rows.
- Keep distinct rounds such as `MAY26` and `MAY26 (2)` separate even though they share a calendar month.
- Preserve manual charges and FTO EXTRA charges.
- Never reassign a charge based only on month when period ID is ambiguous.
- Enforce the allocation safety ceiling used by FTO snapshot reconciliation before committing.
- Preserve ledger history; no physical deletion of financial rows.

## Edge Function changes

Replace the multi-request `action === "change-fto-period"` implementation with existing admin authorization, strict request validation, and one call to the new RPC. Map validation/conflict errors to HTTP responses. Do not perform financial reads or writes in the Edge Function before or after the RPC.

## Required tests

The current PostgreSQL fixture covers:
- moving between `MAY26` and `MAY26 (2)`;
- transactions first seen before, during, and after an exemption interval;
- manual charges and FTO EXTRA charges remaining unchanged;
- payment allocation preservation;
- superseded FTO rows retained and voided;
- transaction links rebuilt from eligible transactions;
- allocation-safety rejection rolling back the entire reassignment;
- audit entries and idempotent repeated invocation.

A static lock-order regression assertion now verifies that card advisory locks precede the destination period row lock. The PostgreSQL fixture also injects a failure during replacement-ledger insertion and verifies that the batch period, old ledger row, transaction links, and audit rows all roll back. A true two-session concurrency test remains useful follow-up hardening.

Wire the SQL integration test into the existing CI PostgreSQL test workflow.

## Scope boundary

This PR contains the SQL RPC, Edge Function refactor, static safeguards, and PostgreSQL integration fixture. It remains draft until CI and review pass. Do not apply the migration or deploy the Edge Function without explicit approval.

## Verified database constraints and implementation decisions

Inspection of the current production schema and data confirms:

- `vbgramg_payment_allocations.transaction_id` references a payment ledger row and its `period_id` is immutable on update. The allocation validation trigger also rejects non-payment ledger rows. The Change Period RPC must leave these rows untouched.
- `vbgramg_fto_transactions.ledger_entry_id` references `vbgramg_charge_ledger(id)` with `ON DELETE SET NULL`; it is the FTO-to-ledger link that must be reassigned atomically.
- `vbgramg_charge_ledger.is_voided` already exists and is included in financial eligibility calculations. The ledger has no soft-delete timestamp or separate supersession relation.
- FTO batch rows are uniquely identified by `fto_number`; transaction rows are unique by `(batch_id, reference_no)`.
- The current production snapshot has 747 FTO transactions, 709 linked transactions, 7 batches, and 709 active FTO ledger rows. No FTO ledger row currently has a payment allocation, and no duplicate active FTO ledger groups were found. These are baseline observations, not assumptions the RPC may rely on.

### Keeper and supersession rules

- Only active, non-voided FTO ledger rows may be selected as keepers.
- Mark every active FTO import row for an affected card/round as `is_voided = true`, preserving its before-image in `vbgramg_ledger_audit`.
- Create a fresh aggregate row when eligible FTO charges remain; if none remain, leave the old rows voided and transaction links cleared.
- Never unvoid a historical row automatically. If a previously voided FTO charge becomes applicable again, create a new ledger row so the superseded history remains intact.
- Keep FTO EXTRA rows outside the FTO component rebuild. Keep manual rows outside the rebuild.
- Before changing a ledger row, reject unexpected references from payment allocations, refund reconciliations, waiver allocations, or contribution-extra records rather than mutating or deleting a referenced financial record.
- Apply an allocation-safety ceiling to every affected card/round, including non-FTO charges (including FTO EXTRA), waiver allocations, and payment allocations. Reject the whole reassignment if the revised eligible charges cannot support existing commitments.
- Record an audit row for material ledger changes/voiding, including before/after JSON and actor identity, using the existing `vbgramg_ledger_audit` table.

The RPC must derive affected cards and source/destination rounds from the batch and database rows after locking. Client-supplied card lists, transaction lists, or ledger IDs must not be trusted as the scope of the operation.
