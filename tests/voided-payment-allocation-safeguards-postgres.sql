-- Disposable PostgreSQL integration test for the dynamic safeguard migration.
-- This fixture supplies minimal functions with the exact source fragments the
-- migration expects, then verifies migration application and runtime behavior.
-- Run only against a disposable database:
--   createdb vbgramg_voided_payment_test
--   PGDATABASE=vbgramg_voided_payment_test psql -v ON_ERROR_STOP=1 -f tests/voided-payment-allocation-safeguards-postgres.sql

CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY,
  job_card_number text NOT NULL,
  entry_type text NOT NULL,
  amount numeric(12,2) NOT NULL,
  is_voided boolean NOT NULL DEFAULT false
);

CREATE TABLE public.vbgramg_payment_allocations (
  id uuid PRIMARY KEY,
  transaction_id uuid NOT NULL,
  job_card_number text NOT NULL,
  amount numeric(12,2) NOT NULL
);

CREATE FUNCTION public.vbgramg_contribution_fifo_breakdown(p_job_card_number text)
RETURNS TABLE(payment_id uuid)
LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
  WITH card_ledger AS (
    SELECT id, entry_type, is_voided
    FROM public.vbgramg_charge_ledger
    WHERE job_card_number = p_job_card_number
  ),
  payment_ids AS (
    SELECT id FROM card_ledger WHERE entry_type = 'payment'
  )
  SELECT id FROM payment_ids;
END;
$function$;

CREATE FUNCTION public.vbgramg_replace_payment_allocations(
  p_transaction_id uuid,
  p_allocations jsonb,
  p_job_card_number text,
  p_actor uuid
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  tx public.vbgramg_charge_ledger%ROWTYPE;
  v_card text := p_job_card_number;
BEGIN
  SELECT * INTO tx
  FROM public.vbgramg_charge_ledger
  WHERE id = p_transaction_id;

  IF NOT FOUND OR tx.entry_type <> 'payment' OR tx.job_card_number IS DISTINCT FROM v_card THEN
    RAISE EXCEPTION 'Valid payment transaction required';
  END IF;

  DELETE FROM public.vbgramg_payment_allocations
  WHERE transaction_id = p_transaction_id;

  RETURN pg_catalog.jsonb_build_object('ok', true);
END;
$function$;

-- Apply the exact migration under review against the disposable fixture.
\ir ../supabase/migrations/20261109100000_ignore_voided_payment_allocations.sql

DO $verify_migration$
DECLARE
  v_fifo_definition text;
  v_replace_definition text;
  v_active uuid := '00000000-0000-0000-0000-000000000001';
  v_voided uuid := '00000000-0000-0000-0000-000000000002';
  v_result uuid[];
  v_error boolean := false;
  v_allocation_count integer;
BEGIN
  v_fifo_definition := pg_catalog.pg_get_functiondef(
    'public.vbgramg_contribution_fifo_breakdown(text)'::regprocedure
  );
  v_replace_definition := pg_catalog.pg_get_functiondef(
    'public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid)'::regprocedure
  );

  IF pg_catalog.strpos(v_fifo_definition, 'AND NOT COALESCE(is_voided, false)') = 0 THEN
    RAISE EXCEPTION 'Migration did not install the FIFO voided-payment filter';
  END IF;
  IF pg_catalog.strpos(v_replace_definition, 'OR COALESCE(tx.is_voided, false)') = 0 THEN
    RAISE EXCEPTION 'Migration did not install the replacement RPC voided-payment guard';
  END IF;

  INSERT INTO public.vbgramg_charge_ledger(id,job_card_number,entry_type,amount,is_voided)
  VALUES
    (v_active,'MZ-TEST','payment',100,false),
    (v_voided,'MZ-TEST','payment',200,true);

  SELECT array_agg(payment_id ORDER BY payment_id)
    INTO v_result
  FROM public.vbgramg_contribution_fifo_breakdown('MZ-TEST');

  IF v_result IS DISTINCT FROM ARRAY[v_active]::uuid[] THEN
    RAISE EXCEPTION 'FIFO returned incorrect payment IDs: %', v_result;
  END IF;

  INSERT INTO public.vbgramg_payment_allocations(id,transaction_id,job_card_number,amount)
  VALUES ('00000000-0000-0000-0000-000000000010',v_voided,'MZ-TEST',50);

  BEGIN
    PERFORM public.vbgramg_replace_payment_allocations(
      v_voided, '[]'::jsonb, 'MZ-TEST', NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := true;
  END;

  IF NOT v_error THEN
    RAISE EXCEPTION 'Replacement RPC unexpectedly accepted a voided payment';
  END IF;

  SELECT count(*) INTO v_allocation_count
  FROM public.vbgramg_payment_allocations
  WHERE transaction_id = v_voided;

  IF v_allocation_count <> 1 THEN
    RAISE EXCEPTION 'Rejected replacement modified existing allocation rows';
  END IF;
END;
$verify_migration$;

SELECT 'voided payment migration PostgreSQL tests passed' AS result;
