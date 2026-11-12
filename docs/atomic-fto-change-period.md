# Atomic FTO Change Period — implementation plan

> Status: design / draft PR only. This document does not change runtime behavior or production data.

## Problem

The `change-fto-period` action in `supabase/functions/vbgramg-contribution-data/index.ts` currently performs a period reassignment as a sequence of independent PostgREST requests. It updates the batch first, then recalculates affected transactions and ledger rows, and finally changes transaction-to-ledger links.

A failure partway through can leave the batch, charge ledger, and transaction links inconsistent. The current path also physically deletes duplicate or no-longer-needed FTO charge ledger rows, which is not appropriate for an auditable financial ledger.

## Target design

Move the complete reassignment into one PostgreSQL RPC invoked once by the Edge Function. PostgreSQL must own the transaction boundary and perform all validation, locking, recalculation, ledger changes, and link updates atomically.

### Required transaction behavior

1. Validate the batch, destination period, month label, and period status inside the RPC. Edge Function pre-reads are not authoritative.
2. Lock the FTO batch and affected job cards. Acquire the shared transaction-scoped advisory lock for every affected card using the exact namespace already used by exemption and snapshot operations: `contribution-card:<job-card-number>`.
3. Acquire card locks in lexical order to avoid deadlocks.
4. Re-read all transactions and relevant batches/periods after locks are acquired. Determine all old and new contribution rounds that must be recalculated.
5. Re-evaluate immutable first-seen eligibility inside the transaction using each FTO transaction's `created_at` and `vbgramg_contribution_exemption_history` intervals. A transaction first seen during an exemption interval remains ineligible even if the exemption later ends. Do not substitute the current active-exemption list for interval history.
6. Preserve the existing FTO charge formula and stored transaction `calculated_charge` values. This workflow changes period assignment, not calculation parameters.
7. Rebuild only the FTO charge component for affected card/round pairs. Preserve manual charges and FTO EXTRA charges as independent ledger entries.
8. Never modify payment ledger rows or `vbgramg_payment_allocations`.
9. Do not physically delete ledger rows. Retain superseded FTO charge rows for audit and mark them voided using the existing `is_voided` lifecycle field. Define keeper/voiding behavior with integration tests before merge.
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

Add PostgreSQL integration coverage for:
- moves between two rounds in the same month (e.g. `MAY26` to `MAY26 (2)`) and between months;
- transactions first seen before, during, and after exemption intervals;
- exemption changes serializing with Change Period through the shared card lock;
- manual charges and FTO EXTRA charges remaining unchanged;
- payment rows and allocations remaining unchanged;
- old FTO charge rows retained and voided, not deleted;
- batch period fields, ledger rows, and transaction links agreeing;
- allocation-safety rejection rolling back the entire reassignment;
- injected failure after an early write rolling back all writes;
- idempotent repeated invocation;
- deterministic multi-card lock ordering.

Wire the SQL integration test into the existing CI PostgreSQL test workflow.

## Scope boundary

This PR is a design checkpoint only. The SQL RPC, Edge Function refactor, and integration tests are follow-up implementation work. Do not apply a migration or deploy an Edge Function from this draft.

## Verified database constraints and implementation decisions

Inspection of the current production schema and data confirms:

- `vbgramg_payment_allocations.transaction_id` references a payment ledger row and its `period_id` is immutable on update. The allocation validation trigger also rejects non-payment ledger rows. The Change Period RPC must leave these rows untouched.
- `vbgramg_fto_transactions.ledger_entry_id` references `vbgramg_charge_ledger(id)` with `ON DELETE SET NULL`; it is the FTO-to-ledger link that must be reassigned atomically.
- `vbgramg_charge_ledger.is_voided` already exists and is included in financial eligibility calculations. The ledger has no soft-delete timestamp or separate supersession relation.
- FTO batch rows are uniquely identified by `fto_number`; transaction rows are unique by `(batch_id, reference_no)`.
- The current production snapshot has 747 FTO transactions, 709 linked transactions, 7 batches, and 709 active FTO ledger rows. No FTO ledger row currently has a payment allocation, and no duplicate active FTO ledger groups were found. These are baseline observations, not assumptions the RPC may rely on.

### Keeper and supersession rules

- Only active, non-voided FTO ledger rows may be selected as keepers.
- Reuse one existing active row for a card/round when it represents the recalculated FTO component; update its references and amount without changing the stored transaction charge values.
- When multiple active FTO rows are found for the same card/round, retain one deterministic keeper and mark the others `is_voided = true`.
- When a card/round no longer has an eligible FTO charge, mark its active FTO ledger row(s) voided and clear the affected transaction links.
- Never unvoid a historical row automatically. If a previously voided FTO charge becomes applicable again, create a new ledger row so the superseded history remains intact.
- Keep FTO EXTRA rows outside the FTO component rebuild. Keep manual rows outside the rebuild.
- Before changing a ledger row, reject unexpected references from payment allocations, refund reconciliations, waiver allocations, or contribution-extra records rather than mutating or deleting a referenced financial record.
- Apply the same allocation-safety ceiling as snapshot reconciliation to each affected card/round, accounting for non-FTO charges (including FTO EXTRA), waivers, and existing allocations. Reject the whole reassignment if the revised eligible charges cannot support current allocations.
- Record an audit row for material ledger changes/voiding, including before/after JSON and actor identity, using the existing `vbgramg_ledger_audit` table.

The RPC must derive affected cards and source/destination rounds from the batch and database rows after locking. Client-supplied card lists, transaction lists, or ledger IDs must not be trusted as the scope of the operation.
