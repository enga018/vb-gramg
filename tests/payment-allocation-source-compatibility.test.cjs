const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const migration = fs.readFileSync(
  path.join(__dirname, "../supabase/migrations/20261118230000_allow_payment_allocation_sources.sql"),
  "utf8"
);

test("payment allocation uniqueness includes allocation source", () => {
  assert.match(migration, /ALTER TABLE public\.vbgramg_payment_allocations[\s\S]*?DROP CONSTRAINT IF EXISTS vbgramg_payment_allocations_transaction_id_period_id_key/);
  assert.match(migration, /CREATE UNIQUE INDEX vbgramg_payment_allocations_transaction_period_source_key[\s\S]*?\(transaction_id, period_id, allocation_source\)/);
});

test("automatic FIFO upserts only the fifo_auto allocation row", () => {
  assert.match(migration, /AND a\.allocation_source = ''fifo_auto''/);
  assert.match(migration, /ON CONFLICT \(transaction_id, period_id, allocation_source\) DO UPDATE/);
});

test("allocation replacement deletes only the requested source", () => {
  assert.match(migration, /AND allocation_source = p_allocation_source/);
  assert.match(migration, /allocation_source <> p_allocation_source/);
  assert.match(migration, /total \+ v_other_allocated \+ v_refunded > tx\.amount/);
});

test("migration fails closed if expected production function definitions drift", () => {
  assert.equal((migration.match(/RAISE EXCEPTION 'Could not locate/g) || []).length, 5);
});


const contributionFunction = fs.readFileSync(
  path.join(__dirname, "../supabase/functions/vbgramg-contribution-data/index.ts"),
  "utf8"
);
const coRevisionMigration = fs.readFileSync(
  path.join(__dirname, "../supabase/migrations/20261119120000_rebuild_charge_level_fifo_on_co_revision.sql"),
  "utf8"
);

test("CO calculation preview is admin-only and validates whole-number parameters", () => {
  const start = contributionFunction.indexOf('if(action==="preview-fto-co-revision")');
  const end = contributionFunction.indexOf('if(action==="apply-fto-co-revision")', start);
  assert.ok(start >= 0 && end > start, "CO preview action must exist before Apply");
  const action = contributionFunction.slice(start, end);
  assert.match(action, /approved\.role!=="admin"/);
  assert.match(action, /Number\.isInteger\(divisor\)/);
  assert.match(action, /Number\.isInteger\(multiplier\)/);
  assert.match(action, /vbgramg_get_fto_revision_snapshot/);
  assert.match(action, /vbgramg_calculate_fto_charges/);
});

test("CO calculation preview simulates charge-level FIFO without writing financial rows", () => {
  const start = contributionFunction.indexOf('if(action==="preview-fto-co-revision")');
  const end = contributionFunction.indexOf('if(action==="apply-fto-co-revision")', start);
  const action = contributionFunction.slice(start, end);
  assert.match(action, /unlinkedWaivers/);
  assert.match(action, /charge_payment_allocations/);
  assert.match(action, /manual_charge_links/);
  assert.match(action, /allocation_source/);
  assert.match(action, /entry\.entry_type==="payment"/);
  assert.match(action, /started_at/);
  assert.match(action, /ended_at/);
  assert.match(action, /newByLedger\.set\(ledgerId,next\)/);
  assert.match(action, /vbgramg_simulate_charge_level_fifo/);
  assert.match(action, /p_period_waivers:periodWaivers/);
  assert.match(action, /allocation_fingerprint:finalFingerprint/);
  assert.doesNotMatch(action, /\.from\([^)]*\)\.(?:insert|update|upsert|delete)\(/);
});

test("CO Apply checks the preview fingerprint and replaces only automatic charge-level FIFO rows", () => {
  assert.match(coRevisionMigration, /p_expected_allocation_fingerprint text/);
  assert.match(coRevisionMigration, /v_current_allocation_fingerprint is distinct from p_expected_allocation_fingerprint/);
  assert.match(coRevisionMigration, /vbgramg_rebuild_charge_level_fifo_for_card\(v_card\)/);
  assert.match(coRevisionMigration, /a\.allocation_source='fifo_auto'/);
  assert.match(coRevisionMigration, /a\.allocation_source<>'fifo_auto'/);
  assert.match(coRevisionMigration, /p_period_waivers jsonb/);
  assert.match(coRevisionMigration, /v_period_due := v_period\.charge_total-v_period_fixed-v_legacy_period-v_period_waived/);
  assert.match(coRevisionMigration, /v_simulation->>'status' in \('simulated','exempt'\)/);
});
