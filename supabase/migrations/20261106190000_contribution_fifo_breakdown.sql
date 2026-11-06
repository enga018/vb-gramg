CREATE OR REPLACE FUNCTION public.vbgramg_contribution_fifo_breakdown(p_job_card_number text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$
WITH card_ledger AS (
  SELECT l.*
  FROM public.vbgramg_charge_ledger AS l
  WHERE l.job_card_number = p_job_card_number
),
eligible AS (
  SELECT
    l.*,
    GREATEST(COALESCE(l.amount, 0), 0)::numeric AS charge_amount,
    COALESCE(
      l.charge_period::text,
      l.entry_date::text,
      l.created_at::date::text,
      ''
    ) AS sort_key,
    ROW_NUMBER() OVER (
      ORDER BY
        COALESCE(l.charge_period::text, l.entry_date::text, l.created_at::date::text, '') COLLATE "C",
        COALESCE(l.entry_date::text, '') COLLATE "C",
        COALESCE(l.created_at::text, '') COLLATE "C"
    ) AS fifo_order
  FROM card_ledger AS l
  WHERE NOT COALESCE(l.is_voided, false)
    AND NOT COALESCE(l.is_deferred, false)
    AND l.entry_type IN ('charge', 'other_charge', 'sanitationFee')
    AND NOT (
      l.entry_type = 'charge'
      AND BTRIM(COALESCE(l.note, '')) = 'Return'
    )
),
totals AS (
  SELECT
    COALESCE(SUM(GREATEST(COALESCE(amount, 0), 0)) FILTER (
      WHERE NOT COALESCE(is_voided, false) AND entry_type = 'payment'
    ), 0)::numeric AS paid,
    COALESCE(SUM(GREATEST(COALESCE(amount, 0), 0)) FILTER (
      WHERE NOT COALESCE(is_voided, false)
        AND entry_type IN ('refund', 'return')
        OR (
          NOT COALESCE(is_voided, false)
          AND entry_type = 'charge'
          AND BTRIM(COALESCE(note, '')) = 'Return'
        )
    ), 0)::numeric AS returns,
    COALESCE(SUM(GREATEST(COALESCE(amount, 0), 0)) FILTER (
      WHERE NOT COALESCE(is_voided, false)
        AND entry_type IN ('charge_waiver', 'forgive')
    ), 0)::numeric AS waived
  FROM card_ledger
),
payment_ids AS (
  SELECT id
  FROM card_ledger
  WHERE entry_type = 'payment'
),
allocations_by_period AS (
  SELECT
    a.period_id,
    SUM(GREATEST(COALESCE(a.amount, 0), 0))::numeric AS allocated_amount
  FROM public.vbgramg_payment_allocations AS a
  JOIN payment_ids AS p ON p.id = a.transaction_id
  GROUP BY a.period_id
),
waiver_running AS (
  SELECT
    e.*,
    COALESCE(
      SUM(e.charge_amount) OVER (
        ORDER BY e.fifo_order ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0
    ) AS prior_charge_amount
  FROM eligible AS e
),
after_waiver AS (
  SELECT
    w.*,
    LEAST(
      w.charge_amount,
      GREATEST(0, t.waived - w.prior_charge_amount)
    )::numeric AS waived_amount,
    GREATEST(
      0,
      w.charge_amount - LEAST(w.charge_amount, GREATEST(0, t.waived - w.prior_charge_amount))
    )::numeric AS remaining_after_waiver
  FROM waiver_running AS w
  CROSS JOIN totals AS t
),
explicit_running AS (
  SELECT
    w.*,
    COALESCE(a.allocated_amount, 0)::numeric AS period_allocation,
    COALESCE(
      SUM(w.remaining_after_waiver) OVER (
        PARTITION BY w.period_id
        ORDER BY w.fifo_order
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0
    ) AS prior_period_remaining
  FROM after_waiver AS w
  LEFT JOIN allocations_by_period AS a
    ON a.period_id = w.period_id
),
after_explicit AS (
  SELECT
    e.*,
    LEAST(
      e.remaining_after_waiver,
      GREATEST(0, e.period_allocation - e.prior_period_remaining)
    )::numeric AS explicit_used,
    GREATEST(
      0,
      e.remaining_after_waiver -
      LEAST(e.remaining_after_waiver, GREATEST(0, e.period_allocation - e.prior_period_remaining))
    )::numeric AS remaining_after_explicit
  FROM explicit_running AS e
),
credit AS (
  SELECT
    GREATEST(0, t.paid - t.returns - COALESCE(SUM(e.explicit_used), 0))::numeric AS pooled_credit,
    t.paid,
    t.returns,
    t.waived
  FROM totals AS t
  LEFT JOIN after_explicit AS e ON true
  GROUP BY t.paid, t.returns, t.waived
),
pooled_running AS (
  SELECT
    e.*,
    c.pooled_credit,
    COALESCE(
      SUM(e.remaining_after_explicit) OVER (
        ORDER BY e.fifo_order ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0
    ) AS prior_global_remaining
  FROM after_explicit AS e
  CROSS JOIN credit AS c
),
calculated AS (
  SELECT
    p.*,
    LEAST(
      p.remaining_after_explicit,
      GREATEST(0, p.pooled_credit - p.prior_global_remaining)
    )::numeric AS pooled_used
  FROM pooled_running AS p
),
entry_rows AS (
  SELECT
    c.*,
    (c.explicit_used + c.pooled_used)::numeric AS allocated,
    GREATEST(0, c.remaining_after_explicit - c.pooled_used)::numeric AS due,
    CASE
      WHEN c.entry_type IN ('other_charge', 'sanitationFee')
        THEN 'special:' || c.id::text
      WHEN c.entry_type = 'charge' AND c.note ~* '^FTO EXTRA:'
        THEN 'extra:' || COALESCE(c.period_id::text, c.sort_key) || ':' || c.id::text
      ELSE 'period:' || CASE
        WHEN c.period_id IS NOT NULL THEN 'id:' || c.period_id::text
        ELSE c.sort_key
      END
    END AS group_key,
    CASE
      WHEN c.entry_type IN ('other_charge', 'sanitationFee') THEN 'Other charge'
      WHEN c.entry_type = 'charge' AND c.note ~* '^FTO EXTRA:' THEN 'Extra charge'
      ELSE COALESCE(
        NULLIF(BTRIM(p.period_name), ''),
        CASE
          WHEN COALESCE(c.charge_period::text, c.entry_date::text, c.created_at::date::text, '') ~ '^\\d{4}-\\d{2}'
          THEN TO_CHAR(
            TO_DATE(SUBSTRING(COALESCE(c.charge_period::text, c.entry_date::text, c.created_at::date::text) FROM 1 FOR 7) || '-01', 'YYYY-MM-DD'),
            'FMMonth YYYY'
          )
          ELSE 'Monthly charge'
        END
      )
    END AS group_label
  FROM calculated AS c
  LEFT JOIN public.vbgramg_periods AS p ON p.id = c.period_id
),
groups AS (
  SELECT
    group_key,
    MIN(sort_key) AS first_sort,
    MIN(group_label) AS label,
    SUM(charge_amount)::numeric AS total,
    SUM(allocated)::numeric AS paid,
    SUM(due)::numeric AS due,
    SUM(waived_amount)::numeric AS waived,
    JSONB_AGG(
      (TO_JSONB(e) - 'fifo_order' - 'sort_key' - 'prior_charge_amount'
        - 'remaining_after_waiver' - 'period_allocation' - 'prior_period_remaining'
        - 'remaining_after_explicit' - 'pooled_credit' - 'prior_global_remaining'
        - 'pooled_used' - 'explicit_used' - 'group_key' - 'group_label'
        - 'charge_amount')
      || JSONB_BUILD_OBJECT(
        'remaining', e.due,
        'allocated', e.allocated,
        'waivedAmount', e.waived_amount
      )
      ORDER BY e.fifo_order
    ) AS entries
  FROM entry_rows AS e
  GROUP BY group_key
)
SELECT JSONB_BUILD_OBJECT(
  'job_card_number', p_job_card_number,
  'paid_total', c.paid,
  'returns_total', c.returns,
  'waived_total', c.waived,
  'groups', COALESCE((
    SELECT JSONB_AGG(
      JSONB_BUILD_OBJECT(
        'key', g.group_key,
        'label', g.label,
        'entries', g.entries,
        'total', g.total,
        'paid', g.paid,
        'due', g.due,
        'waived', g.waived,
        'firstSort', g.first_sort
      )
      ORDER BY g.first_sort COLLATE "C", g.label COLLATE "C"
    )
    FROM groups AS g
  ), '[]'::jsonb)
)
FROM credit AS c;
$function$


REVOKE ALL ON FUNCTION public.vbgramg_contribution_fifo_breakdown(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vbgramg_contribution_fifo_breakdown(text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_contribution_fifo_breakdown(text) TO service_role;
