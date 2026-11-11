\set ON_ERROR_STOP on

-- Dedicated CI database only. All fixture records are synthetic.
create table public.vbgramg_fto_batches (
  id uuid primary key,
  fto_number text not null,
  contribution_period text not null
);
create table public.vbgramg_fto_transactions (
  id uuid primary key,
  batch_id uuid not null,
  reference_no text not null,
  job_card_number text not null,
  status text,
  is_current boolean,
  is_in_scope boolean
);
create table public.vbgramg_charge_ledger (
  id uuid primary key,
  job_card_number text not null,
  entry_type text not null,
  amount numeric(14,2) not null,
  period_id uuid,
  entry_date date,
  created_at timestamptz not null default now(),
  is_deferred boolean not null default false,
  is_voided boolean not null default false,
  note text
);
create table public.vbgramg_periods (
  id uuid primary key,
  period_name text,
  contribution_month date,
  period_date date,
  created_at timestamptz not null default now()
);
create table public.vbgramg_payment_allocations (
  id uuid primary key,
  transaction_id uuid not null,
  period_id uuid not null,
  job_card_number text not null,
  amount numeric(14,2) not null,
  created_at timestamptz not null default now()
);
create table public.vbgramg_payment_refund_reconciliations (
  id uuid primary key,
  payment_id uuid not null,
  refund_id uuid not null,
  job_card_number text not null,
  amount numeric(14,2) not null,
  created_at timestamptz not null default now()
);
create table public.vbgramg_waiver_period_allocations (
  id uuid primary key,
  waiver_id uuid not null,
  period_id uuid not null,
  job_card_number text not null,
  amount numeric(14,2) not null,
  created_at timestamptz not null default now()
);
create table public.vbgramg_contribution_exemptions (
  job_card_number text primary key,
  note text
);
create table public.vbgramg_contribution_exemption_history (
  id uuid primary key,
  job_card_number text not null,
  started_at timestamptz not null,
  ended_at timestamptz
);

do $$
begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end
$$;

\ir ../supabase/migrations/20261111110537_create_fto_revision_preview.sql

insert into public.vbgramg_fto_batches(id,fto_number,contribution_period)
values ('00000000-0000-0000-0000-000000000001','TEST-FTOSNAP-001','JAN26');

insert into public.vbgramg_periods(id,period_name,contribution_month,period_date,created_at) values
('00000000-0000-0000-0000-000000000010','FEB26',null,'2025-12-01','2026-02-01T00:00:00Z'),
('00000000-0000-0000-0000-000000000011','JAN26','2026-01-01','2026-01-01','2026-01-01T00:00:00Z'),
('00000000-0000-0000-0000-000000000012','MAR26','2026-03-01','2026-03-01','2026-03-01T00:00:00Z');

insert into public.vbgramg_fto_transactions(
  id,batch_id,reference_no,job_card_number,status,is_current,is_in_scope
) values
('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000001','REF-001','JC-001','processed',true,true),
('00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000001','REF-002','JC-002','processed',true,false),
('00000000-0000-0000-0000-000000000103','00000000-0000-0000-0000-000000000001','REF-003','JC-003','processed',false,true);

-- The snapshot must include every ledger row for an affected card, not just
-- the selected FTO charge: manual charges, payments, waivers and voided rows
-- all matter to an accurate preview.
insert into public.vbgramg_charge_ledger(
  id,job_card_number,entry_type,amount,period_id,entry_date,created_at,is_voided,note
) values
('00000000-0000-0000-0000-000000000201','JC-001','charge',80,'00000000-0000-0000-0000-000000000011','2026-01-01','2026-01-01T01:00:00Z',false,'FTO'),
('00000000-0000-0000-0000-000000000202','JC-001','payment',50,null,'2026-01-05','2026-01-05T01:00:00Z',false,'Bank payment'),
('00000000-0000-0000-0000-000000000203','JC-001','charge_waiver',10,null,'2026-01-06','2026-01-06T01:00:00Z',false,'Waiver'),
('00000000-0000-0000-0000-000000000206','JC-001','forgive',15,null,'2026-01-07','2026-01-07T01:00:00Z',false,'Partially linked legacy waiver'),
('00000000-0000-0000-0000-000000000204','JC-001','other_charge',25,'00000000-0000-0000-0000-000000000010','2026-02-01','2026-02-01T01:00:00Z',true,'Voided charge'),
('00000000-0000-0000-0000-000000000205','JC-002','charge',90,'00000000-0000-0000-0000-000000000011','2026-01-01','2026-01-01T01:00:00Z',false,'Out of scope');

insert into public.vbgramg_payment_allocations(
  id,transaction_id,period_id,job_card_number,amount
) values
('00000000-0000-0000-0000-000000000301','00000000-0000-0000-0000-000000000202','00000000-0000-0000-0000-000000000011','JC-001',20);

insert into public.vbgramg_payment_refund_reconciliations(
  id,payment_id,refund_id,job_card_number,amount
) values
('00000000-0000-0000-0000-000000000401','00000000-0000-0000-0000-000000000202','00000000-0000-0000-0000-000000000499','JC-001',5);

insert into public.vbgramg_waiver_period_allocations(
  id,waiver_id,period_id,job_card_number,amount
) values
('00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000203','00000000-0000-0000-0000-000000000011','JC-001',10),
('00000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-000000000206','00000000-0000-0000-0000-000000000011','JC-001',4);

insert into public.vbgramg_contribution_exemptions(job_card_number,note)
values ('JC-001','Synthetic exemption');
insert into public.vbgramg_contribution_exemption_history(id,job_card_number,started_at,ended_at)
values ('00000000-0000-0000-0000-000000000601','JC-001','2026-01-01T00:00:00Z',null);

do $$
declare
  v_snapshot jsonb;
begin
  v_snapshot := public.vbgramg_get_fto_revision_snapshot(
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000012'
  );

  if v_snapshot->'batch'->>'fto_number' <> 'TEST-FTOSNAP-001' then
    raise exception 'Snapshot returned the wrong FTO batch';
  end if;

  if jsonb_array_length(v_snapshot->'transactions') <> 3 then
    raise exception 'Snapshot did not preserve all batch transaction rows';
  end if;

  if jsonb_array_length(v_snapshot->'job_cards') <> 2
     or not (v_snapshot->'job_cards' ? 'JC-001')
     or not (v_snapshot->'job_cards' ? 'JC-003') then
    raise exception 'Snapshot omitted superseded in-scope card history: %', v_snapshot->'job_cards';
  end if;

  if jsonb_array_length(v_snapshot->'periods') <> 3
     or not exists (
       select 1
       from jsonb_array_elements(v_snapshot->'periods') p
       where p->>'id' = '00000000-0000-0000-0000-000000000012'
     ) then
    raise exception 'Snapshot omitted the proposed target period with no ledger activity';
  end if;

  if jsonb_array_length(v_snapshot->'ledger_entries') <> 5 then
    raise exception 'Snapshot omitted ledger context for the affected card';
  end if;

  if jsonb_array_length(v_snapshot->'payment_allocations') <> 1
     or (v_snapshot->'payment_allocations'->0->>'amount')::numeric <> 20
     or v_snapshot->'payment_allocations'->0->>'payment_is_voided' <> 'false' then
    raise exception 'Snapshot payment allocation evidence is incomplete';
  end if;

  if jsonb_array_length(v_snapshot->'payment_refunds') <> 1
     or (v_snapshot->'payment_refunds'->0->>'amount')::numeric <> 5 then
    raise exception 'Snapshot payment refund evidence is incomplete';
  end if;

  if jsonb_array_length(v_snapshot->'waiver_allocations') <> 1
     or (v_snapshot->'waiver_allocations'->0->>'amount')::numeric <> 10 then
    raise exception 'Snapshot waiver evidence is incomplete';
  end if;

  if jsonb_array_length(v_snapshot->'unlinked_legacy_waivers') <> 1
     or v_snapshot->'unlinked_legacy_waivers'->0->>'entry_type' <> 'forgive'
     or (v_snapshot->'unlinked_legacy_waivers'->0->>'unlinked_amount')::numeric <> 11
     or (v_snapshot->'unlinked_legacy_waivers'->0->>'linked_amount')::numeric <> 4 then
    raise exception 'Snapshot did not identify the partially linked legacy waiver remainder: %',
      v_snapshot->'unlinked_legacy_waivers';
  end if;

  if jsonb_array_length(v_snapshot->'active_exemptions') <> 1
     or jsonb_array_length(v_snapshot->'exemption_history') <> 1 then
    raise exception 'Snapshot exemption evidence is incomplete';
  end if;

  if v_snapshot->'periods'->0->>'period_name' <> 'JAN26'
     or (v_snapshot->'periods'->0->>'fifo_order')::integer <> 1 then
    raise exception 'Snapshot FIFO period ordering is incorrect';
  end if;

  if has_function_privilege('anon',
       'public.vbgramg_get_fto_revision_snapshot(uuid,uuid)','EXECUTE')
     or has_function_privilege('authenticated',
       'public.vbgramg_get_fto_revision_snapshot(uuid,uuid)','EXECUTE')
     or not has_function_privilege('service_role',
       'public.vbgramg_get_fto_revision_snapshot(uuid,uuid)','EXECUTE') then
    raise exception 'Snapshot function grants are incorrect';
  end if;

  begin
    perform public.vbgramg_get_fto_revision_snapshot(
      '00000000-0000-0000-0000-000000000999'
    );
    raise exception 'Unknown batch unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm = 'Unknown batch unexpectedly accepted' then raise; end if;
  end;
end
$$;

select 'FTO revision snapshot PostgreSQL tests passed' as result;
