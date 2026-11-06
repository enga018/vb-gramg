-- Keep legacy Return charges out of deferred totals as well.
-- The shared JavaScript calculation classifies these rows as returns before
-- checking the deferred flag.
CREATE OR REPLACE FUNCTION public.vbgramg_contribution_financial_summary()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
WITH ledger_by_card AS (
  SELECT
    l.job_card_number,
    (array_agg(l.person_name ORDER BY l.entry_date DESC NULLS LAST, l.created_at DESC, l.id DESC))[1] AS person_name,
    count(*) FILTER (WHERE NOT l.is_voided) AS active_entry_count,
    COALESCE(sum(l.amount) FILTER (
      WHERE NOT l.is_voided
        AND l.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND NOT l.is_deferred
        AND NOT (l.entry_type = 'charge' AND btrim(COALESCE(l.note, '')) = 'Return')
    ), 0)::numeric(14,2) AS charges,
    COALESCE(sum(l.amount) FILTER (
      WHERE NOT l.is_voided
        AND l.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND l.is_deferred
        AND NOT (l.entry_type = 'charge' AND btrim(COALESCE(l.note, '')) = 'Return')
    ), 0)::numeric(14,2) AS deferred,
    COALESCE(sum(l.amount) FILTER (
      WHERE NOT l.is_voided AND l.entry_type = 'payment'
    ), 0)::numeric(14,2) AS paid,
    COALESCE(sum(l.amount) FILTER (
      WHERE NOT l.is_voided AND l.entry_type IN ('charge_waiver', 'forgive')
    ), 0)::numeric(14,2) AS waived,
    COALESCE(sum(l.amount) FILTER (
      WHERE NOT l.is_voided
        AND (
          l.entry_type IN ('refund', 'return')
          OR (l.entry_type = 'charge' AND btrim(COALESCE(l.note, '')) = 'Return')
        )
    ), 0)::numeric(14,2) AS returns,
    (array_agg(l.amount ORDER BY l.entry_date DESC NULLS LAST, l.created_at DESC, l.id DESC)
      FILTER (
        WHERE NOT l.is_voided
          AND l.entry_type IN ('charge', 'other_charge', 'sanitationFee')
          AND NOT (l.entry_type = 'charge' AND btrim(COALESCE(l.note, '')) = 'Return')
      ))[1] AS latest_charge_amount
  FROM public.vbgramg_charge_ledger AS l
  GROUP BY l.job_card_number
),
card_states AS (
  SELECT
    c.*,
    (e.job_card_number IS NOT NULL) AS exempt,
    GREATEST(c.charges - LEAST(c.charges, c.waived), 0)::numeric(14,2) AS total_charged,
    (
      GREATEST(c.charges - LEAST(c.charges, c.waived), 0)
      - c.paid
      + c.returns
    )::numeric(14,2) AS calculated_balance
  FROM ledger_by_card AS c
  LEFT JOIN public.vbgramg_contribution_exemptions AS e
    ON e.job_card_number = c.job_card_number
),
visible_cards AS (
  SELECT
    job_card_number,
    COALESCE(person_name, '') AS person_name,
    exempt,
    CASE WHEN exempt THEN 0::numeric ELSE charges END AS charges,
    CASE WHEN exempt THEN 0::numeric ELSE deferred END AS deferred,
    CASE WHEN exempt THEN 0::numeric ELSE paid END AS paid,
    CASE WHEN exempt THEN 0::numeric ELSE waived END AS waived,
    CASE WHEN exempt THEN 0::numeric ELSE returns END AS returns,
    CASE WHEN exempt THEN 0::numeric ELSE total_charged END AS "totalCharged",
    CASE WHEN exempt THEN 0::numeric ELSE calculated_balance END AS balance,
    latest_charge_amount,
    active_entry_count
  FROM card_states
)
SELECT jsonb_build_object(
  'summaries',
  COALESCE((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.job_card_number) FROM visible_cards AS v), '[]'::jsonb),
  'totals',
  (SELECT jsonb_build_object(
      'job_cards', count(*),
      'exempt_job_cards', count(*) FILTER (WHERE exempt),
      'charges', COALESCE(sum(charges), 0),
      'deferred', COALESCE(sum(deferred), 0),
      'paid', COALESCE(sum(paid), 0),
      'waived', COALESCE(sum(waived), 0),
      'returns', COALESCE(sum(returns), 0),
      'total_charged', COALESCE(sum("totalCharged"), 0),
      'net_balance', COALESCE(sum(balance), 0),
      'total_outstanding', COALESCE(sum(GREATEST(balance, 0)), 0),
      'overpaid_job_cards', count(*) FILTER (WHERE balance < 0),
      'due_job_cards', count(*) FILTER (WHERE balance > 0)
    ) FROM visible_cards),
  'ledger_rows', (SELECT count(*) FROM public.vbgramg_charge_ledger)
);
$function$;
