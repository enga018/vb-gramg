const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");

const migration = fs.readFileSync(
  "supabase/migrations/20261108120000_allow_distinct_charge_round_dates.sql",
  "utf8",
);
const periodsFunction = fs.readFileSync(
  "supabase/functions/vbgramg-periods/index.ts",
  "utf8",
);
const periodsPage = fs.readFileSync("periods.html", "utf8");
const workflow = fs.readFileSync(
  ".github/workflows/test-ledger-calculations.yml",
  "utf8",
);

test("migration removes only the first-day restriction on round dates", () => {
  assert.match(
    migration,
    /DROP CONSTRAINT IF EXISTS vbgramg_periods_period_date_first_day/i,
  );
  assert.doesNotMatch(
    migration,
    /ADD CONSTRAINT\s+vbgramg_periods_period_date_first_day/i,
  );
  assert.match(
    migration,
    /period_id is the accounting identity/i,
  );
});

test("period creation assigns a distinct date to each round", () => {
  assert.match(periodsFunction, /const periodDate = `\$\{month\.slice\(0, 7\)\}-\$\{String\(periodNumber\)\.padStart\(2, "0"\)\}`/);
  assert.match(periodsFunction, /period_date: periodDate, contribution_month: month/);
});

test("Periods page reports the date returned by the server", () => {
  assert.match(
    periodsPage,
    /r\.period\.period_date/,
  );
  assert.doesNotMatch(
    periodsPage,
    /r\.period\.period_name\s*\+\s*" dated "\s*\+\s*periodDate/,
  );
});

test("CI runs the static and isolated PostgreSQL round-date tests", () => {
  assert.match(workflow, /tests\/charge-round-period-dates\.test\.cjs/);
  assert.match(workflow, /tests\/charge-round-period-dates-postgres\.sql/);
});
