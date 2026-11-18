-- Isolated PostgreSQL integration test for source-aware payment allocations.
-- Run only against a disposable database.
--   createdb vbgramg_allocation_sources_test
--   PGDATABASE=vbgramg_allocation_sources_test psql -v ON_ERROR_STOP=1 -f tests/payment-allocation-source-compatibility-postgres.sql

CREATE TABLE public.vbgramg_payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL,
  period_id uuid NOT NULL,
  job_card_number text NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  allocation_source text NOT NULL DEFAULT 'manual',
  UNIQUE (transaction_id, period_id)
);
CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY,
  entry_type text NOT NULL,
  amount numeric(12,2) NOT NULL
);
CREATE TABLE public.vbgramg_payment_refund_reconciliations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL,
  amount numeric(12,2) NOT NULL
);

-- Minimal function fixtures deliberately retain the exact production source
-- fragments that the migration replaces. The migration must fail closed if
-- those source fragments change unexpectedly.
CREATE FUNCTION public.vbgramg_auto_allocate_unallocated_payments(p_job_card_number text)
RETURNS void LANGUAGE plpgsql AS $function$
DECLARE
  v_period record;
  v_payment record;
BEGIN
  FOR v_period IN SELECT gen_random_uuid() AS id LOOP
    PERFORM 1
    FROM public.vbgramg_payment_allocations a
    WHERE a.transaction_id = v_payment.id AND a.period_id = v_period.id;

    INSERT INTO public.vbgramg_payment_allocations
      (transaction_id, period_id, job_card_number, amount, allocation_source)
    VALUES
      (gen_random_uuid(), v_period.id, p_job_card_number, 1, 'fifo_auto')
    ON CONFLICT (transaction_id, period_id) DO UPDATE
      SET amount = EXCLUDED.amount;
  END LOOP;
END;
$function$;

CREATE FUNCTION public.vbgramg_replace_payment_allocations(
  p_transaction_id uuid,
  p_allocations jsonb,
  p_allocation_source text DEFAULT 'manual',
  p_user_id uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE
  tx public.vbgramg_charge_ledger%ROWTYPE;
  total numeric(12,2) := 0;
  v_refunded numeric(12,2) := 0;
BEGIN
  SELECT * INTO tx FROM public.vbgramg_charge_ledger
  WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND OR tx.entry_type <> 'payment' THEN
    RAISE EXCEPTION 'Valid payment required';
  END IF;

  SELECT COALESCE(sum((item->>'amount')::numeric),0)::numeric(12,2)
  INTO total
  FROM jsonb_array_elements(p_allocations) item;

  SELECT COALESCE(sum(r.amount),0)::numeric(12,2)
  INTO v_refunded
  FROM public.vbgramg_payment_refund_reconciliations r
  WHERE r.payment_id = p_transaction_id;

  IF total + v_refunded > tx.amount THEN
    RAISE EXCEPTION 'Allocations plus refunds exceed payment';
  END IF;

  DELETE FROM public.vbgramg_payment_allocations
  WHERE transaction_id = p_transaction_id;

  INSERT INTO public.vbgramg_payment_allocations
    (transaction_id, period_id, job_card_number, amount, allocation_source)
  SELECT p_transaction_id, (item->>'period_id')::uuid, 'MZ-TEST',
         (item->>'amount')::numeric, p_allocation_source
  FROM jsonb_array_elements(p_allocations) item;

  RETURN jsonb_build_object('ok',true);
END;
$function$;

\ir ../supabase/migrations/20261118230000_allow_payment_allocation_sources.sql

DO $test$
DECLARE
  v_payment uuid := '00000000-0000-0000-0000-000000000101';
  v_period uuid := '00000000-0000-0000-0000-000000000201';
  v_manual numeric(12,2);
  v_fifo numeric(12,2);
  v_failed boolean := false;
BEGIN
  INSERT INTO public.vbgramg_charge_ledger(id,entry_type,amount)
  VALUES (v_payment,'payment',100);

  -- Same payment and period may hold independent allocation sources.
  INSERT INTO public.vbgramg_payment_allocations
    (transaction_id,period_id,job_card_number,amount,allocation_source)
  VALUES
    (v_payment,v_period,'MZ-TEST',30,'manual'),
    (v_payment,v_period,'MZ-TEST',20,'fifo_auto');

  SELECT amount INTO v_manual FROM public.vbgramg_payment_allocations
  WHERE transaction_id=v_payment AND period_id=v_period AND allocation_source='manual';
  SELECT amount INTO v_fifo FROM public.vbgramg_payment_allocations
  WHERE transaction_id=v_payment AND period_id=v_period AND allocation_source='fifo_auto';
  IF v_manual<>30 OR v_fifo<>20 THEN
    RAISE EXCEPTION 'Distinct allocation sources did not coexist: manual %, fifo %',v_manual,v_fifo;
  END IF;

  -- Replace manual source. Existing fifo_auto row must survive.
  PERFORM public.vbgramg_replace_payment_allocations(
    v_payment,
    jsonb_build_array(jsonb_build_object('period_id',v_period,'amount',25)),
    'manual',NULL
  );
  SELECT amount INTO v_manual FROM public.vbgramg_payment_allocations
  WHERE transaction_id=v_payment AND period_id=v_period AND allocation_source='manual';
  SELECT amount INTO v_fifo FROM public.vbgramg_payment_allocations
  WHERE transaction_id=v_payment AND period_id=v_period AND allocation_source='fifo_auto';
  IF v_manual<>25 OR v_fifo<>20 THEN
    RAISE EXCEPTION 'Replacing manual source modified another source: manual %, fifo %',v_manual,v_fifo;
  END IF;

  -- Combined allocations and refunds cannot exceed the payment amount.
  INSERT INTO public.vbgramg_payment_refund_reconciliations(payment_id,amount)
  VALUES (v_payment,60);
  BEGIN
    PERFORM public.vbgramg_replace_payment_allocations(
      v_payment,
      jsonb_build_array(jsonb_build_object('period_id',v_period,'amount',30)),
      'manual',NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'Replacement accepted combined allocations plus refunds above payment amount';
  END IF;

  -- Failed replacement is atomic: both prior source rows remain unchanged.
  SELECT amount INTO v_manual FROM public.vbgramg_payment_allocations
  WHERE transaction_id=v_payment AND period_id=v_period AND allocation_source='manual';
  SELECT amount INTO v_fifo FROM public.vbgramg_payment_allocations
  WHERE transaction_id=v_payment AND period_id=v_period AND allocation_source='fifo_auto';
  IF v_manual<>25 OR v_fifo<>20 THEN
    RAISE EXCEPTION 'Rejected replacement changed existing source rows';
  END IF;
END;
$test$;

SELECT 'payment allocation source compatibility tests passed' AS result;
