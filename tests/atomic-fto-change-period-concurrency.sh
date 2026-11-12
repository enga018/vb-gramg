#!/usr/bin/env bash
set -euo pipefail

job_card="CARD/CONCURRENT"
batch_id="10000000-0000-0000-0000-000000000003"
destination_period="00000000-0000-0000-0000-000000000002"

# Session A holds the same card advisory lock that Change Period must acquire.
psql -v ON_ERROR_STOP=1 -c "BEGIN; SELECT pg_advisory_xact_lock(hashtextextended('contribution-card:${job_card}', 0)); SELECT pg_sleep(3); COMMIT" >/tmp/vbgramg-fto-period-lock-holder.log 2>&1 &
lock_pid=$!

# Wait until PostgreSQL confirms Session A is inside pg_sleep, which means the
# advisory lock has already been acquired. This avoids a timing-only race.
ready=0
for _ in $(seq 1 40); do
  active=$(psql -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND query LIKE '%pg_sleep(3)%' AND state='active'")
  if [[ "$active" -ge 1 ]]; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then
  kill "$lock_pid" 2>/dev/null || true
  echo "Lock-holder session did not acquire its advisory lock."
  exit 1
fi

start_ns=$(date +%s%N)
result=$(psql -v ON_ERROR_STOP=1 -Atqc "SET ROLE service_role; SELECT public.vbgramg_change_fto_period('${batch_id}', '${destination_period}', 'MAY26 (2)', DATE '2026-05-01', '90000000-0000-0000-0000-000000000001')->>'ok'")
end_ns=$(date +%s%N)
wait "$lock_pid"

duration_ms=$(( (end_ns - start_ns) / 1000000 ))
if [[ "$result" != "true" ]]; then
  echo "Change Period RPC did not complete successfully: $result"
  exit 1
fi
if (( duration_ms < 1500 )); then
  echo "Change Period did not wait for the held job-card advisory lock (elapsed ${duration_ms}ms)"
  exit 1
fi

echo "Atomic FTO Change Period two-session lock test passed (${duration_ms}ms wait)"
