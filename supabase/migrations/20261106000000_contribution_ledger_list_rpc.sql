-- Return the complete Contribution ledger in one Data API request.
-- The caller is the authenticated Edge Function using the service_role client.
CREATE OR REPLACE FUNCTION public.vbgramg_contribution_ledger_list()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
  SELECT jsonb_build_object(
    'entries',
    COALESCE(
      jsonb_agg(
        to_jsonb(ledger_row)
        ORDER BY
          ledger_row.job_card_number ASC,
          ledger_row.entry_date ASC,
          ledger_row.id ASC
      ),
      '[]'::jsonb
    ),
    'row_count',
    count(*)
  )
  FROM (
    SELECT
      id,
      job_card_number,
      applicant_name,
      applicant_number,
      applicant_unique_id,
      entry_type,
      amount,
      charge_period,
      period_id,
      entry_date,
      note,
      created_at,
      is_deferred,
      is_voided
    FROM public.vbgramg_charge_ledger
    ORDER BY job_card_number ASC, entry_date ASC, id ASC
  ) AS ledger_row;
$function$;

-- Keep this RPC private to the server-side Edge Function.
REVOKE ALL ON FUNCTION public.vbgramg_contribution_ledger_list() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vbgramg_contribution_ledger_list() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_contribution_ledger_list() TO service_role;
