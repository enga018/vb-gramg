const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const migration = fs.readFileSync(
  path.join(__dirname, "../supabase/migrations/20261109100000_ignore_voided_payment_allocations.sql"),
  "utf8"
);

test("FIFO migration adds a voided-payment predicate to the payment_ids CTE", () => {
  assert.match(migration, /v_fifo_pattern text := 'payment_ids AS/);
  assert.match(migration, /v_fifo_replacement text := '[\s\S]*?WHERE entry_type = ''payment''[\s\S]*?AND NOT COALESCE\(is_voided, false\)/);
});

test("allocation replacement migration rejects voided payments", () => {
  assert.match(migration, /v_replace_pattern text := '[\s\S]*?tx\\\.entry_type <> ''payment''[\s\S]*?tx\\\.job_card_number IS DISTINCT FROM v_card/);
  assert.match(migration, /v_replace_replacement text := '[\s\S]*?OR COALESCE\(tx\.is_voided, false\)/);
  assert.match(migration, /Valid active payment transaction required/);
});

test("migration guards against unexpected upstream function definitions", () => {
  assert.match(migration, /Expected payment_ids predicate not found/);
  assert.match(migration, /Expected payment validation predicate not found/);
  assert.match(migration, /EXECUTE v_fifo/);
  assert.match(migration, /EXECUTE v_replace/);
});
