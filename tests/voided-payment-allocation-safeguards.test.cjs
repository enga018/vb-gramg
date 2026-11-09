const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const migration = fs.readFileSync(
  path.join(__dirname, "../supabase/migrations/20261109100000_ignore_voided_payment_allocations.sql"),
  "utf8"
);

test("FIFO breakdown excludes allocations belonging to voided payments", () => {
  assert.match(migration, /payment_ids AS \([\s\S]*?WHERE entry_type = 'payment'[\s\S]*?AND NOT COALESCE\(is_voided, false\)/);
});

test("allocation replacement rejects voided payments before replacing rows", () => {
  assert.match(migration, /tx\.entry_type <> 'payment'[\s\S]*?OR tx\.job_card_number IS DISTINCT FROM v_card[\s\S]*?OR COALESCE\(tx\.is_voided, false\)/);
});

test("migration guards against unexpected upstream function definitions", () => {
  assert.match(migration, /Expected payment_ids predicate not found/);
  assert.match(migration, /Expected payment validation predicate not found/);
  assert.match(migration, /EXECUTE v_fifo/);
  assert.match(migration, /EXECUTE v_replace/);
});
