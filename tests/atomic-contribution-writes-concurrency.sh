#!/usr/bin/env bash
set -euo pipefail

job_card="MZ-CONCURRENT"
psql -v ON_ERROR_STOP=1 -c "INSERT INTO public.vbgramg_charge_ledger (job_card_number, person_name, entry_type, amount, charge_period, note) VALUES ('${job_card}', 'Concurrent Card', 'charge', 100, DATE '2026-11-01', 'Concurrency fixture')"

# Hold the exact transaction-scoped advisory lock used by the RPC in another
# PostgreSQL session. The RPC call must wait until this transaction commits.
psql -v ON_ERROR_STOP=1 -c "BEGIN; SELECT pg_advisory_xact_lock(hashtextextended('vbgramg-contribution:${job_card}', 0)); SELECT pg_sleep(2); COMMIT" >/tmp/vbgramg-lock-holder.log 2>&1 &
lock_pid=$!
sleep 0.4

start_ns=$(date +%s%N)
result=$(psql -v ON_ERROR_STOP=1 -Atqc "SET ROLE service_role; SELECT public.vbgramg_record_contribution_transaction('${job_card}', 'cash_payment', 1, CURRENT_DATE, 'Concurrency test', gen_random_uuid(), 'tester@example.invalid')->>'ok'")
end_ns=$(date +%s%N)
wait "$lock_pid"

duration_ms=$(( (end_ns - start_ns) / 1000000 ))
if [[ "$result" != "true" ]]; then
  echo "Concurrent RPC did not complete successfully: $result"
  exit 1
fi
if (( duration_ms < 1000 )); then
  echo "RPC did not wait for the existing job-card advisory lock (elapsed ${duration_ms}ms)"
  exit 1
fi

echo "Atomic contribution concurrency lock test passed (${duration_ms}ms wait)"
