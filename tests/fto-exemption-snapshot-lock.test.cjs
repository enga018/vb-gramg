const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const migration = read("supabase/migrations/20261111160000_serialize_fto_snapshot_with_exemptions.sql");

test("FTO snapshot and exemption mutations share one per-job-card advisory lock", () => {
  const lock = /hashtextextended\('contribution-card:'\s*\|\|\s*(?:cards\.job_card_number|v_card),\s*0\)/gi;
  assert.equal((migration.match(lock) || []).length, 2);
  assert.match(migration, /order by cards\.job_card_number/i);
});

test("Atomic FTO snapshot rechecks first-seen exemption eligibility inside PostgreSQL", () => {
  const start = migration.indexOf("create or replace function public.vbgramg_apply_fto_snapshot");
  const end = migration.indexOf("$function$;", start);
  assert.ok(start >= 0 && end > start);
  const snapshot = migration.slice(start, end);
  assert.match(snapshot, /pg_advisory_xact_lock[\s\S]*contribution-card:/i);
  assert.match(snapshot, /left join public\.vbgramg_fto_transactions existing on existing\.id = tx\.id/i);
  assert.match(snapshot, /existing\.created_at is null and tx\.created_at is null/i);
  assert.match(snapshot, /coalesce\(existing\.created_at, tx\.created_at\) < coalesce\(h\.ended_at/i);
  assert.match(snapshot, /reference_no = any\(coalesce\(lr\.reference_numbers/i);
  assert.match(snapshot, /FTO snapshot rejected: a transaction was first seen during a contribution exemption interval/i);
});

test("Snapshot safety check runs before any batch, transaction, or ledger writes", () => {
  const snapshot = migration.slice(
    migration.indexOf("create or replace function public.vbgramg_apply_fto_snapshot"),
    migration.indexOf("$function$;", migration.indexOf("create or replace function public.vbgramg_apply_fto_snapshot"))
  );
  const guard = snapshot.indexOf("FTO snapshot rejected:");
  const batchWrite = snapshot.indexOf("insert into public.vbgramg_fto_batches");
  const transactionWrite = snapshot.indexOf("insert into public.vbgramg_fto_transactions");
  const ledgerWrite = snapshot.indexOf("insert into public.vbgramg_charge_ledger");
  assert.ok(guard > 0 && guard < batchWrite && guard < transactionWrite && guard < ledgerWrite);
});
