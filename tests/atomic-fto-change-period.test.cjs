const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const migration = read("supabase/migrations/20261112100000_atomic_fto_change_period.sql");
const edge = read("supabase/functions/vbgramg-contribution-data/index.ts");

test("Change Period is a service-role-only PostgreSQL transaction", () => {
  assert.match(migration, /create or replace function public\.vbgramg_change_fto_period\([\s\S]*?\) returns jsonb/i);
  assert.match(migration, /security definer\s+set search_path = ''/i);
  assert.match(migration, /revoke all on function public\.vbgramg_change_fto_period[\s\S]*?from public, anon, authenticated/i);
  assert.match(migration, /grant execute on function public\.vbgramg_change_fto_period[\s\S]*?to service_role/i);
});

test("Change Period shares the FTO snapshot and exemption per-card lock namespace", () => {
  assert.match(migration, /hashtextextended\('contribution-card:' \|\| c\.card, 0\)/i);
  assert.match(migration, /order by c\.card/i);
  assert.match(migration, /hashtextextended\('contribution:' \|\| v_card \|\| ':' \|\| v_round_id::text, 0\)/i);
});

test("Change Period uses first-seen exemption intervals and preserves charge snapshots", () => {
  assert.match(migration, /tx\.created_at >= h\.started_at[\s\S]*?tx\.created_at < coalesce\(h\.ended_at/i);
  assert.match(migration, /sum\(tx\.calculated_charge\)/i);
  assert.doesNotMatch(migration, /update public\.vbgramg_fto_transactions[\s\S]{0,500}calculated_charge\s*=/i);
});

test("Change Period retains superseded FTO ledger rows and excludes manual/FTO EXTRA rows", () => {
  assert.match(migration, /set is_voided = true/i);
  assert.doesNotMatch(migration, /delete\s+from\s+public\.vbgramg_charge_ledger/i);
  assert.match(migration, /<> 'FTO EXTRA'/i);
  assert.match(migration, /fto_change_period_voided/i);
  assert.match(migration, /fto_change_period_created/i);
});

test("Change Period preserves payment allocations and checks the allocation ceiling", () => {
  assert.match(migration, /sum\(a\.amount\)/i);
  assert.match(migration, /v_allocated \+ v_waived > v_non_fto \+ v_amount/i);
  assert.doesNotMatch(migration, /delete\s+from\s+public\.vbgramg_payment_allocations/i);
  assert.doesNotMatch(migration, /update\s+public\.vbgramg_payment_allocations/i);
});

test("Edge Function makes one RPC call and no multi-request financial writes", () => {
  const start = edge.indexOf('if(action==="change-fto-period"){');
  const end = edge.indexOf("\n  if(action===", start + 20);
  assert.ok(start >= 0 && end > start);
  const action = edge.slice(start, end);
  assert.match(action, /admin\.rpc\("vbgramg_change_fto_period"/);
  assert.doesNotMatch(action, /admin\.from\("vbgramg_(fto_batches|fto_transactions|charge_ledger)"\)/);
  assert.doesNotMatch(action, /\.update\(|\.insert\(|\.delete\(/);
});
