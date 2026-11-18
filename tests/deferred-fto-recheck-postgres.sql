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
\ir ../supabase/migrations/20261118193000_add_deferred_fto_recheck_run_rpcs.sql
\ir ../supabase/migrations/20261118200000_add_deferred_fto_recheck_recovery.sql

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


-- Exercise run lifecycle RPCs and the atomic success-attempt wrapper.
SET ROLE service_role;
DO $$
DECLARE
  v_actor uuid := '11111111-1111-4111-8111-111111111111';
  v_run_id uuid;
  v_result jsonb;
  v_count integer;
BEGIN
  v_run_id := public.vbgramg_start_fto_recheck_run(v_actor, 1);

  v_result := public.vbgramg_recheck_deferred_ftos_with_run(
    '{
      "ftos":[{
        "ftoNumber":"TEST-DEFERRED-001",
        "rows":[
          {"referenceNo":"REF001","normalizedStatus":"processed"},
          {"referenceNo":"REF002","normalizedStatus":"processed"},
          {"referenceNo":"REF003","normalizedStatus":"blank"},
          {"referenceNo":"REF004","normalizedStatus":"rejected"},
          {"referenceNo":"REF005","normalizedStatus":"rejected"}
        ]
      }]
    }'::jsonb,
    v_actor,
    v_run_id
  );

  IF (v_result->>'fto_count')::integer <> 1 THEN
    RAISE EXCEPTION 'Run wrapper did not return the successful FTO reconciliation result';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.vbgramg_fto_recheck_attempts
  WHERE run_id = v_run_id
    AND batch_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    AND status = 'success'
    AND stage = 'reconciliation'
    AND result ? 'updated_count';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Successful reconciliation and attempt were not committed together';
  END IF;

  v_result := public.vbgramg_complete_fto_recheck_run(
    v_run_id, v_actor, 1, 0, 'completed', null
  );

  IF v_result->>'status' <> 'completed'
     OR (v_result->>'successful_ftos')::integer <> 1 THEN
    RAISE EXCEPTION 'Successful run was not finalized with accurate totals: %', v_result;
  END IF;

  -- A listing-level failure has no FTO attempt records, even if eligible FTOs
  -- were known before the Government listing fetch was attempted.
  v_run_id := public.vbgramg_start_fto_recheck_run(v_actor, 1);
  v_result := public.vbgramg_complete_fto_recheck_run(
    v_run_id, v_actor, 0, 0, 'failed',
    'Government FTO listing could not be fetched or validated.'
  );

  IF v_result->>'status' <> 'failed'
     OR (v_result->>'attempted_ftos')::integer <> 0
     OR (v_result->>'total_ftos')::integer <> 1 THEN
    RAISE EXCEPTION 'Run-level listing failure totals are incorrect: %', v_result;
  END IF;

  SELECT count(*) INTO v_count
  FROM public.vbgramg_fto_recheck_attempts
  WHERE run_id = v_run_id;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Listing-level failure unexpectedly created FTO attempt records';
  END IF;

  -- An individual FTO failure is recorded separately and contributes to the
  -- finalized failed count.
  v_run_id := public.vbgramg_start_fto_recheck_run(v_actor, 1);
  PERFORM public.vbgramg_record_fto_recheck_failure(
    v_run_id,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    v_actor,
    'detail_fetch',
    'Government detail page could not be retrieved.'
  );

  v_result := public.vbgramg_complete_fto_recheck_run(
    v_run_id, v_actor, 0, 1, 'failed', null
  );

  IF (v_result->>'failed_ftos')::integer <> 1 THEN
    RAISE EXCEPTION 'Individual FTO failure was not included in run totals';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.vbgramg_fto_recheck_attempts
  WHERE run_id = v_run_id
    AND status = 'failed'
    AND stage = 'detail_fetch';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Individual FTO failure attempt was not persisted';
  END IF;
END
$$;
RESET ROLE;

-- Verify active heartbeats protect a run and stale runs are safely finalized.
SET ROLE service_role;
DO $$
DECLARE
  v_actor uuid := '11111111-1111-4111-8111-111111111111';
  v_run_id uuid;
  v_recovered integer;
BEGIN
  v_run_id := public.vbgramg_start_fto_recheck_run(v_actor, 1);
  v_recovered := public.vbgramg_recover_stale_fto_recheck_runs(v_actor);
  IF v_recovered <> 0 THEN
    RAISE EXCEPTION 'An active run was incorrectly recovered';
  END IF;
  PERFORM public.vbgramg_heartbeat_fto_recheck_run(v_run_id, v_actor);
END
$$;
RESET ROLE;

INSERT INTO public.vbgramg_fto_recheck_runs (
  id, status, total_ftos, actor, heartbeat_at
) VALUES (
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'running', 2, '11111111-1111-4111-8111-111111111111',
  clock_timestamp() - interval '31 minutes'
);

INSERT INTO public.vbgramg_fto_recheck_attempts (
  run_id, batch_id, status, stage, result, actor
) VALUES (
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'success', 'reconciliation', '{"updated_count":1}'::jsonb,
  '11111111-1111-4111-8111-111111111111'
);

SET ROLE service_role;
DO $$
DECLARE
  v_actor uuid := '11111111-1111-4111-8111-111111111111';
  v_recovered integer;
BEGIN
  v_recovered := public.vbgramg_recover_stale_fto_recheck_runs(v_actor);
  IF v_recovered <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one stale run to be recovered, got %', v_recovered;
  END IF;
END
$$;
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.vbgramg_fto_recheck_runs
    WHERE id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      AND status = 'failed'
      AND completed_at IS NOT NULL
      AND successful_ftos = 1
      AND failed_ftos = 0
      AND error_message ILIKE '%interrupted%'
  ) THEN
    RAISE EXCEPTION 'Stale run was not finalized with its persisted attempt totals';
  END IF;
END
$$;
