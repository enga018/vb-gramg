-- FTO snapshot and contribution-ledger lifecycle states.
-- These flags are intentionally separate from MIS scope and exemption:
--   is_in_scope = whether the FTO transaction belongs to active MIS;
--   is_current  = whether the reference is present in the latest complete batch snapshot;
--   is_voided   = whether a ledger charge is retained for history but excluded from active balances.
--
-- Existing rows default to current / not voided so this schema-only migration does not
-- change any existing contribution totals or payment allocations.

alter table public.vbgramg_fto_transactions
  add column if not exists is_current boolean not null default true;

alter table public.vbgramg_charge_ledger
  add column if not exists is_voided boolean not null default false;

comment on column public.vbgramg_fto_transactions.is_current is
  'True when this reference is present in the latest complete snapshot for its FTO batch. False retains a historical reference omitted from a later snapshot.';

comment on column public.vbgramg_charge_ledger.is_voided is
  'True when this ledger row is retained for audit/history but excluded from active contribution balances. Does not delete or alter linked payment allocations.';

create index if not exists vbgramg_fto_transactions_current_batch_idx
  on public.vbgramg_fto_transactions (batch_id, reference_no)
  where is_current = true;

create index if not exists vbgramg_charge_ledger_active_charge_idx
  on public.vbgramg_charge_ledger (job_card_number, period_id)
  where is_voided = false and entry_type = 'charge';
