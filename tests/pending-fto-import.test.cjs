const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const edge = read("supabase/functions/vbgramg-contribution-data/index.ts");
const page = read("pending-imports.html");

function section(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `Missing start marker: ${startMarker}`);
  const end = source.indexOf(endMarker, start);
  assert.notEqual(end, -1, `Missing end marker: ${endMarker}`);
  return source.slice(start, end);
}

const pendingImport = section(
  edge,
  'if(action==="import-pending-fto"){',
  'if(action==="sync-fto-batch"||action==="import-pending-fto"){'
);
const sync = section(
  edge,
  'if(action==="sync-fto-batch"||action==="import-pending-fto"){',
  'if(action==="sync-fto-status"){'
);

test("Pending FTO import is a separate admin-only action requiring final confirmation", () => {
  assert.match(pendingImport, /approved\.role!=="admin"/);
  assert.match(pendingImport, /body\.final_review_confirmed!==true/);
  assert.match(pendingImport, /classification!=="ELIGIBLE"/);
  assert.match(pendingImport, /vbgramg_fto_batches/);
  assert.match(pendingImport, /alreadyImported/);
});

test("Pending FTO import resumes saved inspection and never refetches Government data", () => {
  assert.match(pendingImport, /vbgramg_fto_inspection_state/);
  assert.match(pendingImport, /validated_transactions/);
  assert.match(pendingImport, /loadActiveMisApplicants\(admin\)/);
  assert.doesNotMatch(pendingImport, /fetch\(|fetch\s*\(/);
  assert.doesNotMatch(pendingImport, /vbgramg-fto-government-details/);
});

test("Import requires a still-open period and revalidates exact Active MIS applicant coverage", () => {
  assert.match(pendingImport, /period\.status!=="open"/);
  assert.match(pendingImport, /period\.contribution_month/);
  assert.match(pendingImport, /mappingByCard\.size!==transactions\.length/);
  assert.match(pendingImport, /transactions\.some\(\(tx:any\)=>!mappingByCard\.has/);
  assert.match(pendingImport, /candidates\.find\(a=>/);
});

test("CO formula is validated and recalculated from saved Government credit amounts", () => {
  assert.match(pendingImport, /Number\(body\.divisor\)/);
  assert.match(pendingImport, /Number\(body\.multiplier\)/);
  assert.match(sync, /admin\.rpc\("vbgramg_calculate_fto_charges"/);
  assert.match(sync, /calculatedByIndex\.get\(rowIndex\)/);
  assert.match(pendingImport, /credit_amount:tx\.creditAmount/);
});

test("Manual charge and mapping replacement choices are independently revalidated", () => {
  assert.match(sync, /manual_charge_actions/);
  assert.match(sync, /manual_charge_amount_confirmations/);
  assert.match(sync, /manual_reconciliation_applicants/);
  assert.match(sync, /confirm_mapping_replacements/);
  assert.match(sync, /!manualReconciliationApplicants\.has\(card\)/);
  assert.match(sync, /confirm the manual charge amount change/i);
});

test("Duplicate references and conflicting transactions block Pending FTO import", () => {
  assert.match(sync, /A reference number became duplicated after the preview/);
  assert.match(sync, /skippedDuplicateReferences=\[\.\.\.new Set\(skippedDuplicateReferences\)\]/);
  assert.match(sync, /different FTO number already has a charge/i);
});

test("Import uses the atomic snapshot RPC and verifies its committed result", () => {
  assert.match(sync, /admin\.rpc\("vbgramg_apply_fto_snapshot"/);
  assert.match(sync, /if\(!rpcResult\?\.committed\)/);
  assert.match(sync, /snapshot_committed:true/);
  assert.match(sync, /Do not re-import this FTO/);
  assert.match(sync, /mapping_save_failed:true/);
});

test("Final review confirmation is invalidated by later review input changes", () => {
  assert.match(page, /id="final-review-confirm"/);
  assert.match(page, /id="import-fto"/);
  assert.match(page, /function invalidateFinalReview\(\)/);
  assert.match(page, /finalReviewReady=false/);
  assert.match(page, /button\.disabled=!finalReviewReady/);
});

test("Import UI sends explicit decisions and handles committed failures without retry", () => {
  assert.match(page, /action:"import-pending-fto"/);
  assert.match(page, /final_review_confirmed:true/);
  assert.match(page, /manual_charge_actions/);
  assert.match(page, /manual_charge_amount_confirmations/);
  assert.match(page, /manual_reconciliation_applicants/);
  assert.match(page, /snapshot_committed/);
  assert.match(page, /do not retry this FTO/i);
});

test("A saved applicant mapping that is no longer active always requires manual review", () => {
  const detail = read("supabase/functions/vbgramg-contribution-data/index.ts");
  assert.match(detail, /const automatic=savedMapping\?\(savedCandidate\|\|null\):\(/);
  assert.match(detail, /reason:savedMapping&&!savedCandidate\?/);
});


test("CO parameters must be whole positive numbers in both FTO workflows and the database", () => {
  const initialImportPage = read("fto-import.html");
  const calculationMigration = read("supabase/migrations/20261118110000_require_integer_fto_co_parameters.sql");
  assert.match(page, /Number\.isInteger\(divisor\)/);
  assert.match(page, /Number\.isInteger\(multiplier\)/);
  assert.match(initialImportPage, /Number\.isInteger\(divisor\)/);
  assert.match(initialImportPage, /Number\.isInteger\(multiplier\)/);
  assert.match(edge, /!Number\.isInteger\(divisor\)/);
  assert.match(edge, /!Number\.isInteger\(multiplier\)/);
  assert.match(calculationMigration, /p_divisor <> trunc\(p_divisor\)/);
  assert.match(calculationMigration, /p_multiplier <> trunc\(p_multiplier\)/);
});

test("Credit Amount remains the authoritative CO input for pending FTO calculation", () => {
  assert.match(page, /credit_amount:tx\.creditAmount/);
  assert.match(edge, /credit_amount:tx\.creditAmount/);
  assert.match(edge, /credit_amount:raw\.credit_amount/);
});
