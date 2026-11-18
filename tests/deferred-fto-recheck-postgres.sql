-- Ephemeral PostgreSQL integration test for deferred Government FTO rechecks.
-- Run from the repository root:
-- psql -v ON_ERROR_STOP=1 -f tests/deferred-fto-recheck-postgres.sql

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END
$$;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text
);
CREATE TABLE public.vbgramg_approved_users (
  email text PRIMARY KEY,
  role text NOT NULL
);
CREATE TABLE public.vbgramg_fto_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fto_number text UNIQUE NOT NULL,
  last_checked_at timestamptz
);
CREATE TABLE public.vbgramg_fto_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.vbgramg_fto_batches(id),
  reference_no text NOT NULL,
  status text,
  processed_date date,
  rejection_reason text,
  last_seen_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  is_current boolean NOT NULL DEFAULT true
);
CREATE TABLE public.vbgramg_fto_status_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id uuid,
  old_status text,
  new_status text,
  old_calculated_charge numeric,
  new_calculated_charge numeric,
  old_processed_date date,
  new_processed_date date,
  changed_by uuid,
  fto_number text,
  reference_no text,
  note text
);

GRANT USAGE ON SCHEMA public, auth TO service_role;
GRANT SELECT ON auth.users TO service_role;
GRANT SELECT ON public.vbgramg_approved_users TO service_role;
GRANT SELECT, UPDATE ON public.vbgramg_fto_batches TO service_role;
GRANT SELECT, UPDATE ON public.vbgramg_fto_transactions TO service_role;
GRANT INSERT ON public.vbgramg_fto_status_history TO service_role;

\ir ../supabase/migrations/20261118170000_add_atomic_deferred_fto_recheck.sql
\ir ../supabase/migrations/20261118190000_add_deferred_fto_recheck_audit.sql

INSERT INTO auth.users(id,email)
VALUES ('11111111-1111-4111-8111-111111111111','admin@example.test');
INSERT INTO public.vbgramg_approved_users(email,role)
VALUES ('admin@example.test','admin');

INSERT INTO public.vbgramg_fto_batches(id,fto_number)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','TEST-DEFERRED-001');

INSERT INTO public.vbgramg_fto_transactions
  (id,batch_id,reference_no,status,processed_date,rejection_reason)
VALUES
  ('00000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','REF001','processed','2026-10-01',NULL),
  ('00000000-0000-4000-8000-000000000002','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','REF002','blank',NULL,NULL),
  ('00000000-0000-4000-8000-000000000003','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','REF003','blank',NULL,NULL),
  ('00000000-0000-4000-8000-000000000004','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','REF004','rejected',NULL,'Rejected by DDO'),
  ('00000000-0000-4000-8000-000000000005','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','REF005','blank',NULL,NULL);

SET ROLE service_role;

DO $$
DECLARE
  v_actor uuid := '11111111-1111-4111-8111-111111111111';
  v_result jsonb;
  v_count integer;
  v_status text;
  v_reason text;
  v_history_count integer;
  v_before_updated_at timestamptz;
BEGIN
  -- Processed/Rejected rows are immutable; Deferred rows can become
  -- Processed/Rejected or remain Deferred.
  v_result := public.vbgramg_recheck_deferred_ftos(
    '{
      "ftos":[{
        "ftoNumber":"TEST-DEFERRED-001",
        "rows":[
          {"referenceNo":"REF001","normalizedStatus":"rejected","processedDate":"","rejectionReason":"Changed upstream"},
          {"referenceNo":"REF002","normalizedStatus":"processed","processedDate":"2026-11-10","rejectionReason":""},
          {"referenceNo":"REF003","normalizedStatus":"blank","processedDate":"","rejectionReason":""},
          {"referenceNo":"REF004","normalizedStatus":"processed","processedDate":"2026-11-11","rejectionReason":""},
          {"referenceNo":"REF005","normalizedStatus":"rejected","processedDate":"","rejectionReason":"Rejected by DDO"}
        ]
      }]
    }'::jsonb,
    v_actor
  );

  IF (v_result->>'updated_count')::integer <> 2
     OR (v_result->>'still_deferred_count')::integer <> 1
     OR (v_result->>'unchanged_count')::integer <> 2 THEN
    RAISE EXCEPTION 'Unexpected aggregate recheck counts: %', v_result;
  END IF;

  SELECT status INTO v_status FROM public.vbgramg_fto_transactions WHERE reference_no='REF002';
  IF v_status <> 'processed' THEN RAISE EXCEPTION 'REF002 was not updated to Processed'; END IF;
  SELECT status INTO v_status FROM public.vbgramg_fto_transactions WHERE reference_no='REF005';
  SELECT rejection_reason INTO v_reason FROM public.vbgramg_fto_transactions WHERE reference_no='REF005';
  IF v_status <> 'rejected' OR v_reason <> 'Rejected by DDO' THEN
    RAISE EXCEPTION 'REF005 was not updated to Rejected with its reason';
  END IF;

  SELECT status INTO v_status FROM public.vbgramg_fto_transactions WHERE reference_no='REF001';
  IF v_status <> 'processed' THEN RAISE EXCEPTION 'Existing Processed REF001 was changed'; END IF;
  SELECT status INTO v_status FROM public.vbgramg_fto_transactions WHERE reference_no='REF004';
  IF v_status <> 'rejected' THEN RAISE EXCEPTION 'Existing Rejected REF004 was changed'; END IF;
  SELECT status INTO v_status FROM public.vbgramg_fto_transactions WHERE reference_no='REF003';
  IF v_status <> 'blank' THEN RAISE EXCEPTION 'Still-Deferred REF003 changed unexpectedly'; END IF;

  SELECT count(*) INTO v_history_count FROM public.vbgramg_fto_status_history;
  IF v_history_count <> 2 THEN
    RAISE EXCEPTION 'Expected exactly two status-history rows, found %', v_history_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.vbgramg_fto_transactions;
  IF v_count <> 5 THEN RAISE EXCEPTION 'Recheck inserted or deleted transactions; count is %', v_count; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.vbgramg_fto_batches
    WHERE fto_number='TEST-DEFERRED-001'
      AND last_deferred_recheck_at IS NOT NULL
      AND last_deferred_recheck_result->>'updated_count' = '2'
      AND last_deferred_recheck_result->>'still_deferred_count' = '1'
  ) THEN
    RAISE EXCEPTION 'Per-FTO recheck timestamp/result was not persisted';
  END IF;

  -- A duplicate reference invalidates the complete submitted table. The
  -- function must fail before any transaction status or audit row changes.
  SELECT updated_at INTO v_before_updated_at
  FROM public.vbgramg_fto_transactions WHERE reference_no='REF003';

  BEGIN
    PERFORM public.vbgramg_recheck_deferred_ftos(
      '{
        "ftos":[{
          "ftoNumber":"TEST-DEFERRED-001",
          "rows":[
            {"referenceNo":"REF001","normalizedStatus":"processed"},
            {"referenceNo":"REF002","normalizedStatus":"processed"},
            {"referenceNo":"REF003","normalizedStatus":"processed"},
            {"referenceNo":"REF003","normalizedStatus":"processed"},
            {"referenceNo":"REF005","normalizedStatus":"rejected"}
          ]
        }]
      }'::jsonb,
      v_actor
    );
    RAISE EXCEPTION 'Duplicate reference should have been rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'Duplicate reference should have been rejected' THEN RAISE; END IF;
    IF position('duplicate reference' in lower(SQLERRM)) = 0 THEN RAISE; END IF;
  END;

  SELECT status INTO v_status FROM public.vbgramg_fto_transactions WHERE reference_no='REF003';
  IF v_status <> 'blank' THEN RAISE EXCEPTION 'Failed recheck partially changed REF003'; END IF;
  SELECT count(*) INTO v_history_count FROM public.vbgramg_fto_status_history;
  IF v_history_count <> 2 THEN RAISE EXCEPTION 'Failed recheck wrote partial history rows'; END IF;
  SELECT count(*) INTO v_count FROM public.vbgramg_fto_transactions;
  IF v_count <> 5 THEN RAISE EXCEPTION 'Failed recheck changed transaction count'; END IF;
END
$$;

RESET ROLE;


-- Verify the new run/attempt audit schema, referential integrity, and API isolation.
DO $$
DECLARE
  v_run_id uuid;
  v_attempt_id uuid;
  v_count integer;
BEGIN
  IF NOT (
    SELECT c.relrowsecurity
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'vbgramg_fto_recheck_runs'
  ) THEN
    RAISE EXCEPTION 'RLS is not enabled on recheck runs';
  END IF;

  IF NOT (
    SELECT c.relrowsecurity
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'vbgramg_fto_recheck_attempts'
  ) THEN
    RAISE EXCEPTION 'RLS is not enabled on recheck attempts';
  END IF;

  IF has_table_privilege('anon', 'public.vbgramg_fto_recheck_runs', 'SELECT')
     OR has_table_privilege('authenticated', 'public.vbgramg_fto_recheck_runs', 'SELECT')
     OR has_table_privilege('service_role', 'public.vbgramg_fto_recheck_runs', 'SELECT') THEN
    RAISE EXCEPTION 'Recheck run table unexpectedly has direct API read grants';
  END IF;

  IF has_table_privilege('anon', 'public.vbgramg_fto_recheck_attempts', 'SELECT')
     OR has_table_privilege('authenticated', 'public.vbgramg_fto_recheck_attempts', 'SELECT')
     OR has_table_privilege('service_role', 'public.vbgramg_fto_recheck_attempts', 'SELECT') THEN
    RAISE EXCEPTION 'Recheck attempt table unexpectedly has direct API read grants';
  END IF;

  INSERT INTO public.vbgramg_fto_recheck_runs (
    status, total_ftos, actor
  ) VALUES (
    'running', 1, '11111111-1111-4111-8111-111111111111'
  ) RETURNING id INTO v_run_id;

  INSERT INTO public.vbgramg_fto_recheck_attempts (
    run_id, batch_id, status, stage, result, actor
  ) VALUES (
    v_run_id,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'success',
    'reconciliation',
    '{"updated_count":2,"still_deferred_count":1,"unchanged_count":2}'::jsonb,
    '11111111-1111-4111-8111-111111111111'
  ) RETURNING id INTO v_attempt_id;

  UPDATE public.vbgramg_fto_recheck_runs
  SET status = 'completed',
      completed_at = clock_timestamp(),
      successful_ftos = 1
  WHERE id = v_run_id;

  SELECT count(*) INTO v_count
  FROM public.vbgramg_fto_recheck_attempts
  WHERE id = v_attempt_id
    AND run_id = v_run_id
    AND batch_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    AND status = 'success'
    AND result->>'updated_count' = '2';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Could not persist and retrieve a successful FTO attempt';
  END IF;

  BEGIN
    INSERT INTO public.vbgramg_fto_recheck_attempts (
      run_id, batch_id, status, stage, error_message, actor
    ) VALUES (
      v_run_id,
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'failed',
      'detail_fetch',
      'Duplicate attempt should fail',
      '11111111-1111-4111-8111-111111111111'
    );
    RAISE EXCEPTION 'Duplicate FTO attempt in one run should have been rejected';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END
$$;
