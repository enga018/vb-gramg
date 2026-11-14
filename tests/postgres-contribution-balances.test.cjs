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

test("contribution summary has no JavaScript financial audit path", () => {
  assert.doesNotMatch(edge, /ledger-calculations\.js/);
  assert.doesNotMatch(edge, /audit_calculations|calculateLedgerState|calculation_audit/);
  const start = edge.indexOf("if(action===\"list-summary\")");
  const end = edge.indexOf("if(action===\"list\")", start);
  assert.ok(start >= 0 && end > start, "Contribution list-summary action must exist");
  const action = edge.slice(start, end);
  assert.match(action, /admin\.rpc\("vbgramg_contribution_financial_summary"\)/);
  assert.doesNotMatch(action, /vbgramg_contribution_ledger_list/);
});

test("contribution FIFO detail is rendered from PostgreSQL, not the retired JavaScript calculator", () => {
  assert.match(edge, /admin\.rpc\("vbgramg_contribution_fifo_breakdown"/);
  assert.match(edge, /fifo_breakdown:fifoBreakdown/);
  assert.match(contribution, /c\.fifo_breakdown\?\.groups/);
  assert.doesNotMatch(contribution, /js\/allocation\.js/);
  assert.equal(fs.existsSync(path.join(__dirname, "..", "js/allocation.js")), false);
  assert.doesNotMatch(contribution, /VBGRAMGAllocation|calculateFifoGroups/);
});

test("desktop Contribution table shows latest named period and a separate status column", () => {
  const migration = read("supabase/migrations/20261113130000_add_latest_contribution_period_to_summary.sql");
  assert.match(migration, /latest_contribution_period/);
  assert.match(migration, /JOIN public\.vbgramg_periods AS p ON p\.id = latest\.period_id/);
  assert.match(migration, /latest\.is_voided/);
  assert.match(migration, /p\.created_at DESC/);
  assert.match(migration, /COALESCE\(p\.contribution_month, p\.period_date, latest\.charge_period\)/);
  for (const column of ["Job Card Number","Head of Household","Last Contribution","Outstanding","Status"]) assert.ok(contribution.includes(column), "Missing desktop column: "+column);
  assert.match(contribution, /c\.latest_contribution_period/);
  assert.doesNotMatch(contribution, /Last Charges/);
  assert.match(contribution, /statusTag\.textContent=dueAmount<0\?'Overpaid':dueAmount>0\?'Due':'Settled'/);
});
