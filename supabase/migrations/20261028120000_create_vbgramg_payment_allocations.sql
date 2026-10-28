-- Period-level allocation records for contribution payments.
-- Existing ledger transactions remain untouched; historical allocation is a separate reviewed task.
create table if not exists public.vbgramg_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.vbgramg_charge_ledger(id) on delete restrict,
  period_id uuid not null references public.vbgramg_periods(id) on delete restrict,
  job_card_number text not null,
  amount numeric(12,2) not null check (amount > 0),
  allocation_source text not null default 'manual' check (allocation_source in ('fifo_auto','manual','historical_evidence','historical_fifo_reviewed')),
  confidence text not null default 'confirmed' check (confidence in ('confirmed','probable','review_required')),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (transaction_id, period_id)
);
create index if not exists idx_vbgramg_payment_allocations_period on public.vbgramg_payment_allocations(period_id);
create index if not exists idx_vbgramg_payment_allocations_transaction on public.vbgramg_payment_allocations(transaction_id);
create index if not exists idx_vbgramg_payment_allocations_job_card on public.vbgramg_payment_allocations(job_card_number);
alter table public.vbgramg_payment_allocations enable row level security;
create or replace function public.vbgramg_validate_payment_allocation()
returns trigger language plpgsql security definer set search_path = public as $$
declare tx public.vbgramg_charge_ledger%rowtype; already_allocated numeric(12,2); has_charge boolean;
begin
 select * into tx from public.vbgramg_charge_ledger where id = new.transaction_id for update;
 if not found then raise exception 'Transaction not found'; end if;
 if tx.entry_type <> 'payment' then raise exception 'Only payment transactions can receive payment allocations'; end if;
 if tx.job_card_number <> new.job_card_number then raise exception 'Allocation job card must match the payment transaction'; end if;
 select coalesce(sum(amount),0) into already_allocated from public.vbgramg_payment_allocations where transaction_id = new.transaction_id and id is distinct from new.id;
 if already_allocated + new.amount > tx.amount then raise exception 'Allocations cannot exceed the original payment amount'; end if;
 select exists(select 1 from public.vbgramg_charge_ledger where period_id = new.period_id and job_card_number = new.job_card_number and entry_type in ('charge','other_charge')) into has_charge;
 if not has_charge then raise exception 'This job card has no charge recorded for the selected period'; end if;
 new.updated_at := now(); return new;
end; $$;
drop trigger if exists trg_vbgramg_validate_payment_allocation on public.vbgramg_payment_allocations;
create trigger trg_vbgramg_validate_payment_allocation before insert or update on public.vbgramg_payment_allocations for each row execute function public.vbgramg_validate_payment_allocation();
comment on table public.vbgramg_payment_allocations is 'Allocates one payment transaction across contribution periods without duplicating or modifying the original payment.';
