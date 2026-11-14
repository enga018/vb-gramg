-- Add the latest named contribution round to each card summary.
-- Financial totals and balance calculations remain unchanged.
-- Include every active MIS job card in the financial summary, including
-- cards with no ledger rows. This preserves the current list-summary population.
CREATE OR REPLACE FUNCTION public.vbgramg_contribution_financial_summary()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
WITH active_mis AS (
  SELECT s.active_import_id
  FROM public.vbgramg_mis_state AS s
  WHERE s.singleton = true
),
citizens AS (
  SELECT
    c.job_card_number,
    COALESCE(c.person_name, '') AS person_name
  FROM active_mis AS m
  JOIN public.vbgramg_mis_contribution_lookup AS l
    ON l.import_id = m.active_import_id
  CROSS JOIN LATERAL jsonb_to_recordset(l.payload->'citizens')
    AS c(job_card_number text, person_name text)
),
ledger_by_card AS (
  SELECT
    l.job_card_number,
    COALESCE(sum(GREATEST(COALESCE(l.amount, 0), 0)) FILTER (
      WHERE NOT l.is_voided
        AND l.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND NOT l.is_deferred
        AND NOT (l.entry_type = 'charge' AND btrim(COALESCE(l.note, '')) = 'Return')
    ), 0)::numeric(14,2) AS charges,
    COALESCE(sum(GREATEST(COALESCE(l.amount, 0), 0)) FILTER (
      WHERE NOT l.is_voided
        AND l.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND l.is_deferred
        AND NOT (l.entry_type = 'charge' AND btrim(COALESCE(l.note, '')) = 'Return')
    ), 0)::numeric(14,2) AS deferred,
    COALESCE(sum(GREATEST(COALESCE(l.amount, 0), 0)) FILTER (
      WHERE NOT l.is_voided AND l.entry_type = 'payment'
    ), 0)::numeric(14,2) AS paid,
    COALESCE(sum(GREATEST(COALESCE(l.amount, 0), 0)) FILTER (
      WHERE NOT l.is_voided AND l.entry_type IN ('charge_waiver', 'forgive')
    ), 0)::numeric(14,2) AS waived,
    COALESCE(sum(GREATEST(COALESCE(l.amount, 0), 0)) FILTER (
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
      ))[1] AS latest_charge_amount,
    (
      SELECT p.period_name
      FROM public.vbgramg_charge_ledger AS latest
      JOIN public.vbgramg_periods AS p ON p.id = latest.period_id
      WHERE latest.job_card_number = l.job_card_number
        AND NOT latest.is_voided
        AND latest.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND NOT (latest.entry_type = 'charge' AND btrim(COALESCE(latest.note, '')) = 'Return')
      ORDER BY
        COALESCE(p.contribution_month, p.period_date, latest.charge_period) DESC NULLS LAST,
        p.created_at DESC,
        latest.entry_date DESC NULLS LAST,
        latest.created_at DESC,
        latest.id DESC
      LIMIT 1
    ) AS latest_contribution_period,
    count(*) FILTER (WHERE NOT l.is_voided) AS active_entry_count
  FROM public.vbgramg_charge_ledger AS l
  GROUP BY l.job_card_number
),
card_states AS (
  SELECT
    c.job_card_number,
    c.person_name,
    (e.job_card_number IS NOT NULL) AS exempt,
    COALESCE(l.charges, 0)::numeric(14,2) AS charges,
    COALESCE(l.deferred, 0)::numeric(14,2) AS deferred,
    COALESCE(l.paid, 0)::numeric(14,2) AS paid,
    COALESCE(l.waived, 0)::numeric(14,2) AS waived,
    COALESCE(l.returns, 0)::numeric(14,2) AS returns,
    GREATEST(COALESCE(l.charges, 0) - LEAST(COALESCE(l.charges, 0), COALESCE(l.waived, 0)), 0)::numeric(14,2) AS total_charged,
    (
      GREATEST(COALESCE(l.charges, 0) - LEAST(COALESCE(l.charges, 0), COALESCE(l.waived, 0)), 0)
      - COALESCE(l.paid, 0)
      + COALESCE(l.returns, 0)
    )::numeric(14,2) AS calculated_balance,
    l.latest_charge_amount,
    l.latest_contribution_period,
    COALESCE(l.active_entry_count, 0) AS active_entry_count
  FROM citizens AS c
  LEFT JOIN ledger_by_card AS l ON l.job_card_number = c.job_card_number
  LEFT JOIN public.vbgramg_contribution_exemptions AS e ON e.job_card_number = c.job_card_number
),
visible_cards AS (
  SELECT
    job_card_number,
    person_name,
    exempt,
    CASE WHEN exempt THEN 0::numeric ELSE charges END AS charges,
    CASE WHEN exempt THEN 0::numeric ELSE deferred END AS deferred,
    CASE WHEN exempt THEN 0::numeric ELSE paid END AS paid,
    CASE WHEN exempt THEN 0::numeric ELSE waived END AS waived,
    CASE WHEN exempt THEN 0::numeric ELSE returns END AS returns,
    CASE WHEN exempt THEN 0::numeric ELSE total_charged END AS "totalCharged",
    CASE WHEN exempt THEN 0::numeric ELSE calculated_balance END AS balance,
    latest_charge_amount,
    latest_contribution_period,
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
