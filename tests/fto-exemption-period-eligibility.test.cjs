const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const migration = read("supabase/migrations/20261111120000_track_contribution_exemption_intervals.sql");
const edge = read("supabase/functions/vbgramg-contribution-data/index.ts");

test("Exemption intervals are retained and only one open interval is allowed per job card", () => {
  assert.match(migration, /create table if not exists public\.vbgramg_contribution_exemption_history/i);
  assert.match(migration, /started_at timestamptz not null/i);
  assert.match(migration, /ended_at timestamptz/i);
  assert.match(migration, /where ended_at is null/i);
  assert.match(migration, /coalesce\(e\.created_at, now\(\)\)/i);
});

test("Exemption state and history are opened or closed atomically through a service-role RPC", () => {
  assert.match(migration, /create or replace function public\.vbgramg_set_contribution_exemption/i);
  assert.match(migration, /pg_advisory_xact_lock/i);
  assert.match(migration, /insert into public\.vbgramg_contribution_exemption_history/i);
  assert.match(migration, /set ended_at = v_now, ended_by = p_actor_user_id/i);
  assert.match(migration, /revoke all on function[\s\S]*from public, anon, authenticated/i);
  assert.match(migration, /grant execute on function[\s\S]*to service_role/i);
});

test("Removing an exemption no longer rebuilds charges from retained FTO history", () => {
  const start = edge.indexOf('if(action==="save-exemption"){');
  const end = edge.indexOf('if(action==="work-demand-balances"){', start);
  assert.ok(start >= 0 && end > start);
  const block = edge.slice(start, end);
  assert.match(block, /vbgramg_set_contribution_exemption/);
  assert.doesNotMatch(block, /vbgramg_fto_transactions/);
  assert.doesNotMatch(block, /vbgramg_charge_ledger/);
});

test("FTO re-import eligibility uses immutable created_at against every exemption interval", () => {
  assert.match(edge, /firstSeenByReference/);
  assert.match(edge, /created_at/);
  assert.match(edge, /isEligibleFirstSeen/);
  assert.match(edge, /timestamp>=started&&timestamp<ended/);
  assert.match(edge, /isEligibleFirstSeen\(input\)/);
});

test("FTO period reassignment filters out transactions first seen during exemption intervals", () => {
  assert.match(edge, /eligibleInScopeTxs/);
  assert.match(edge, /select\("id,batch_id,reference_no,job_card_number,person_name,calculated_charge,status,processed_date,is_in_scope,last_seen_at,created_at"\)/);
  assert.match(edge, /exemptionHistory/);
  assert.match(edge, /for\(const tx of eligibleInScopeTxs\)/);
});


test("Re-importing an FTO after a status change preserves the original first-seen timestamp", () => {
  const snapshot = read("supabase/migrations/20261103170000_add_atomic_fto_snapshot_rpc.sql");
  const transactionUpsertStart = snapshot.indexOf("on conflict (id) do update set", snapshot.indexOf("insert into public.vbgramg_fto_transactions"));
  const transactionUpsertEnd = snapshot.indexOf(";", transactionUpsertStart);
  assert.ok(transactionUpsertStart >= 0 && transactionUpsertEnd > transactionUpsertStart);
  const transactionUpsert = snapshot.slice(transactionUpsertStart, transactionUpsertEnd);

  // The Edge Function reuses the existing transaction ID and created_at,
  // even when status/processed_date changes during a later FTO synchronization.
  assert.match(edge, /created_at:old\?\.created_at\|\|nowIso/);
  assert.match(edge, /String\(old\.status\|\|""\)!==String\(row\.status\|\|""\)/);
  assert.match(edge, /statusHistory\.push\(\{transaction_id:id,old_status:old\?\.status\?\?null,new_status:row\.status/);

  // PostgreSQL updates mutable snapshot fields but never overwrites created_at.
  assert.match(transactionUpsert, /status=excluded\.status/);
  assert.doesNotMatch(transactionUpsert, /created_at\s*=/);
});
