const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const edge = read("supabase/functions/vbgramg-contribution-data/index.ts");
const contribution = read("contribution.html");
const demand = read("demand.html");

test("Work Demand balances are sourced from the PostgreSQL financial summary", () => {
  const start = edge.indexOf('if(action==="work-demand-balances")');
  const end = edge.indexOf('if(action==="job-card-details")', start);
  assert.ok(start >= 0 && end > start, "Work Demand action must exist");
  const action = edge.slice(start, end);
  assert.match(action, /admin\.rpc\("vbgramg_contribution_financial_summary"\)/);
  assert.match(action, /balances\[id\]=Number\(summary\.balance\)\|\|0/);
  assert.doesNotMatch(action, /from\("vbgramg_charge_ledger"\)/);
  assert.doesNotMatch(action, /calculateLedgerState/);
  assert.match(demand, /action:'work-demand-balances'/);
});

test("Contribution card details receive and apply database-calculated balances", () => {
  const start = edge.indexOf('if(action==="job-card-details")');
  const end = edge.indexOf('if(action==="list-summary")', start);
  assert.ok(start >= 0 && end > start, "Job-card detail action must exist");
  const action = edge.slice(start, end);
  assert.match(action, /admin\.rpc\("vbgramg_contribution_financial_summary"\)/);
  assert.match(action, /card_summary:cardSummary/);
  assert.match(contribution, /summaryByCard\.set\(String\(c\.id\),data\.card_summary\)/);
  assert.doesNotMatch(contribution, /calculateLedgerState/);
  assert.doesNotMatch(contribution, /loadedLedgerCards/);
});

test("The existing database summary remains the financial source of truth", () => {
  const migration = read("supabase/migrations/20261106190000_include_active_mis_cards_in_financial_summary.sql");
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.vbgramg_contribution_financial_summary\(\)/);
  assert.match(migration, /NOT l\.is_deferred/);
  assert.match(migration, /NOT l\.is_voided/);
  assert.match(migration, /vbgramg_contribution_exemptions/);
});
