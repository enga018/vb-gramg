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
  assert.equal((migration.match(/RAISE EXCEPTION 'Could not locate/g) || []).length, 4);
});
