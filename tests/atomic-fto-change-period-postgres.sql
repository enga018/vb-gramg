-- Isolated PostgreSQL integration test for the atomic FTO Change Period RPC.
\set ON_ERROR_STOP on

do $$
begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;

create table public.vbgramg_periods (
  id uuid primary key,
  period_name text not null,
  period_date date,
  contribution_month date,
  status text not null default 'open',
  created_at timestamptz not null default now()
);
create table public.vbgramg_contribution_exemptions (job_card_number text primary key);
create table public.vbgramg_contribution_exemption_history (
  id uuid primary key default gen_random_uuid(),
  job_card_number text not null,
  started_at timestamptz not null,
  ended_at timestamptz
);
create table public.vbgramg_fto_batches (
  id uuid primary key,
  fto_number text not null unique,
  contribution_period text not null,
  ledger_charge_period date,
  period_id uuid,
  last_checked_at timestamptz not null default now()
);
create table public.vbgramg_fto_transactions (
  id uuid primary key,
  batch_id uuid not null,
  reference_no text not null,
  job_card_number text not null,
  person_name text not null,
  calculated_charge numeric,
  status text not null,
  processed_date date,
  created_at timestamptz not null,
  is_in_scope boolean not null default true,
  is_current boolean not null default true,
  ledger_entry_id uuid,
  updated_at timestamptz not null default now()
);
create table public.vbgramg_charge_ledger (
  id uuid primary key default gen_random_uuid(),
  job_card_number text not null,
  person_name text not null,
  entry_type text not null,
  amount numeric not null,
  charge_period date,
  entry_date date,
  note text,
  created_by uuid,
  is_deferred boolean not null default false,
  reference_numbers text[],
  period_id uuid,
  is_voided boolean not null default false
);
create table public.vbgramg_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null,
  period_id uuid not null,
  job_card_number text not null,
  amount numeric not null
);
create table public.vbgramg_ledger_audit (
  id uuid primary key default gen_random_uuid(),
  ledger_entry_id uuid,
  job_card_number text not null,
  action text not null,
  actor_user_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.vbgramg_skip_exempt_contribution_write()
returns trigger language plpgsql as $$ begin return new; end $$;
create trigger vbgramg_skip_exempt_ledger_write
before insert or update on public.vbgramg_charge_ledger
for each row execute function public.vbgramg_skip_exempt_contribution_write();

\ir ../supabase/migrations/20261112100000_atomic_fto_change_period.sql

insert into public.vbgramg_periods(id,period_name,period_date,contribution_month)
values
 ('00000000-0000-0000-0000-000000000001','MAY26','2026-05-01','2026-05-01'),
 ('00000000-0000-0000-0000-000000000002','MAY26 (2)','2026-05-01','2026-05-01');

insert into public.vbgramg_fto_batches(id,fto_number,contribution_period,ledger_charge_period,period_id)
values
 ('10000000-0000-0000-0000-000000000001','FTO-CHANGE-1','MAY26','2026-05-01','00000000-0000-0000-0000-000000000001'),
 ('10000000-0000-0000-0000-000000000002','FTO-OTHER-ROUND','MAY26','2026-05-01','00000000-0000-0000-0000-000000000001');

insert into public.vbgramg_fto_transactions
 (id,batch_id,reference_no,job_card_number,person_name,calculated_charge,status,processed_date,created_at)
values
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','REF-ELIGIBLE','CARD/A','Applicant A',10,'processed','2026-05-08','2026-05-09'),
 ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','REF-EXEMPT','CARD/A','Applicant B',20,'processed','2026-05-09','2026-05-11'),
 ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002','REF-OTHER-ROUND','CARD/A','Applicant C',5,'processed','2026-05-10','2026-05-10'),
 ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','REF-CARD-B','CARD/B','Applicant D',1,'processed','2026-05-10','2026-05-10');

insert into public.vbgramg_contribution_exemption_history(job_card_number,started_at,ended_at)
values ('CARD/A','2026-05-10T00:00:00Z','2026-05-12T00:00:00Z');

insert into public.vbgramg_charge_ledger
 (id,job_card_number,person_name,entry_type,amount,charge_period,entry_date,note,is_deferred,reference_numbers,period_id,is_voided)
values
 ('30000000-0000-0000-0000-000000000001','CARD/A','Old FTO','charge',35,'2026-05-01','2026-05-08','FTO import',false,array['REF-ELIGIBLE','REF-EXEMPT','REF-OTHER-ROUND'],'00000000-0000-0000-0000-000000000001',false),
 ('30000000-0000-0000-0000-000000000002','CARD/A','Manual','charge',7,'2026-05-01','2026-05-01','Manual contribution',false,null,'00000000-0000-0000-0000-000000000001',false),
 ('30000000-0000-0000-0000-000000000003','CARD/A','Extra','charge',3,'2026-05-01','2026-05-01','FTO EXTRA',false,null,'00000000-0000-0000-0000-000000000001',false),
 ('30000000-0000-0000-0000-000000000004','CARD/B','Payment','payment',1,'2026-05-01','2026-05-01','Payment',false,null,'00000000-0000-0000-0000-000000000002',false);

insert into public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount)
values ('30000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000002','CARD/B',5);

do $$
declare
  v_failed boolean := false;
  v_result jsonb;
  v_old_voided boolean;
  v_allocation numeric;
  v_new_amount numeric;
  v_old_amount numeric;
begin
  -- Allocation ceiling failure must roll back batch and ledger changes.
  begin
    perform public.vbgramg_change_fto_period(
      '10000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000002',
      'MAY26 (2)','2026-05-01',
      '90000000-0000-0000-0000-000000000001'
    );
  exception when sqlstate '23514' then
    v_failed := true;
  end;
  if not v_failed then raise exception 'Expected allocation-safety rejection'; end if;
  if (select period_id from public.vbgramg_fto_batches where id='10000000-0000-0000-0000-000000000001')
      <> '00000000-0000-0000-0000-000000000001' then
    raise exception 'Failed reassignment did not roll back the batch period';
  end if;
  if (select is_voided from public.vbgramg_charge_ledger where id='30000000-0000-0000-0000-000000000001') then
    raise exception 'Failed reassignment did not roll back ledger voiding';
  end if;

  update public.vbgramg_payment_allocations set amount=0.50
  where transaction_id='30000000-0000-0000-0000-000000000004';

  v_result := public.vbgramg_change_fto_period(
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002',
    'MAY26 (2)','2026-05-01',
    '90000000-0000-0000-0000-000000000001'
  );
  if v_result->>'ok' <> 'true' then raise exception 'Change Period RPC did not report success'; end if;

  select is_voided into v_old_voided from public.vbgramg_charge_ledger
  where id='30000000-0000-0000-0000-000000000001';
  if not v_old_voided then raise exception 'Superseded FTO ledger row was not retained and voided'; end if;

  select amount into v_old_amount from public.vbgramg_charge_ledger
  where job_card_number='CARD/A' and period_id='00000000-0000-0000-0000-000000000001'
    and note='FTO import' and is_voided=false;
  if v_old_amount <> 5 then raise exception 'Old round should retain the other batch charge of 5, got %',v_old_amount; end if;

  select amount into v_new_amount from public.vbgramg_charge_ledger
  where job_card_number='CARD/A' and period_id='00000000-0000-0000-0000-000000000002'
    and note='FTO import' and is_voided=false;
  if v_new_amount <> 10 then raise exception 'New round should include only the eligible 10 charge, got %',v_new_amount; end if;

  if (select count(*) from public.vbgramg_charge_ledger where id in
    ('30000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000003') and is_voided=false) <> 2 then
    raise exception 'Manual and FTO EXTRA charges must remain unchanged';
  end if;

  select sum(amount) into v_allocation from public.vbgramg_payment_allocations
  where transaction_id='30000000-0000-0000-0000-000000000004';
  if v_allocation <> 0.50 then raise exception 'Payment allocation changed unexpectedly'; end if;

  if (select ledger_entry_id from public.vbgramg_fto_transactions where id='20000000-0000-0000-0000-000000000002') is not null then
    raise exception 'First-seen-during-exemption transaction must remain unlinked';
  end if;
  if (select ledger_entry_id from public.vbgramg_fto_transactions where id='20000000-0000-0000-0000-000000000001') is null then
    raise exception 'Eligible transaction was not linked to the rebuilt FTO ledger row';
  end if;
  if not exists(select 1 from public.vbgramg_ledger_audit where action='fto_change_period_voided')
     or not exists(select 1 from public.vbgramg_ledger_audit where action='fto_change_period_created') then
    raise exception 'Expected before/after audit entries for voided and created ledger rows';
  end if;

  -- A repeated invocation is idempotent.
  v_result := public.vbgramg_change_fto_period(
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002',
    'MAY26 (2)','2026-05-01',
    '90000000-0000-0000-0000-000000000001'
  );
  if v_result->>'unchanged' <> 'true' then raise exception 'Repeated Change Period call was not idempotent'; end if;
end $$;

select 'Atomic FTO Change Period PostgreSQL integration tests passed' as result;
