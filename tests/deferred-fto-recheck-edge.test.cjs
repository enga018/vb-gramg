const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const source = fs.readFileSync(path.join(__dirname, "..", "supabase/functions/vbgramg-fto-deferred-recheck/index.ts"), "utf8");

test("deferred recheck is isolated from the initial import endpoints", () => {
  assert.match(source, /vbgramg_recheck_deferred_ftos_with_run/);
  assert.doesNotMatch(source, /vbgramg_import_government_fto_history/);
});

test("only imported FTOs with blank transactions are selected", () => {
  assert.match(source, /from\("vbgramg_fto_transactions"\)[\s\S]*?\.eq\("status","blank"\)/);
  assert.match(source, /from\("vbgramg_fto_batches"\)/);
});

test("complete Government detail rows are validated before reference reconciliation", () => {
  assert.match(source, /Government transaction table was not found|Government table is missing required columns/);
  assert.match(source, /duplicate Reference Number/);
  assert.match(source, /does not reconcile with detail rows/);
  assert.match(source, /Government table is missing stored reference/);
});

test("recheck validates both Government amount columns and passes listing data explicitly", () => {
  assert.match(source, /amount to be credited in rs/);
  assert.match(source, /invalid Amount to Be Credited/);
  assert.match(source, /async function fetchDetail\(url: string, ftoNumber: string, listingRow: string\[\], onStage\?/);
  assert.match(source, /fetchDetail\(candidate\.url,ftoNumber,candidate\.row,nextStage/);
  assert.doesNotMatch(source, /fetchDetail as any/);
});

test("recheck RPC receives only existing references and never calls an insert path", () => {
  assert.match(source, /storedByRef/);
  assert.match(source, /admin\.rpc\("vbgramg_recheck_deferred_ftos_with_run"/);
  assert.doesNotMatch(source, /\.insert\(/);
  assert.doesNotMatch(source, /vbgramg_import_government_fto_history/);
});

test("per-FTO failures are isolated and reported", () => {
  assert.match(source, /failedChecks\.push/);
  assert.match(source, /failedCheckCount/);
  assert.match(source, /data\?\.batches\?\.\[0\]\?\.result/);
});

test("each operation starts and finalizes a durable audit run", () => {
  assert.match(source, /admin\.rpc\("vbgramg_start_fto_recheck_run"/);
  assert.match(source, /p_total_ftos:eligible\.length/);
  assert.match(source, /admin\.rpc\("vbgramg_complete_fto_recheck_run"/);
  assert.match(source, /p_successful_ftos:successfulFtOs,p_failed_ftos:failedFtOs/);
  assert.match(source, /runId,runStatus/);
});

test("listing-level failures finalize the run without creating per-FTO attempts", () => {
  assert.match(source, /p_successful_ftos:0,p_failed_ftos:0,p_status:"failed"/);
  assert.match(source, /Government FTO listing request failed/);
  assert.match(source, /Could not finalize the failed audit run/);
});

test("individual FTO failures are persisted with the stage and safe error message", () => {
  assert.match(source, /admin\.rpc\("vbgramg_record_fto_recheck_failure"/);
  assert.match(source, /p_stage:stage,p_error_message:message/);
  assert.match(source, /auditRecorded:true/);
  assert.match(source, /auditPersistenceError/);
});

test("successful reconciliation and its audit attempt use the atomic run RPC", () => {
  assert.match(source, /admin\.rpc\("vbgramg_recheck_deferred_ftos_with_run"/);
  assert.match(source, /p_run_id:runId/);
  assert.doesNotMatch(source, /admin\.rpc\("vbgramg_recheck_deferred_ftos"/);
});

test("detail fetch and Government table validation are audited as separate stages", () => {
  assert.match(source, /onStage\?\.\("detail_validation"\)/);
  assert.match(source, /nextStage=>\{stage=nextStage;\}/);
});

test("detail aggregate validation uses the supplied FTO listing row", () => {
  assert.match(source, /String\(listingRow\[i\]\|\|""\)/);
  assert.doesNotMatch(source, /String\(listing\[i\]\|\|""\)/);
});

test("error responses preserve whether any reconciliation transaction committed", () => {
  assert.match(source, /let databaseChanged=false/);
  assert.match(source, /databaseChanged=true/);
  assert.match(source, /auditPersistenceError[\s\S]*?databaseChanged\},500/);
  assert.match(source, /Audit finalization failed\.[\s\S]*?databaseChanged\},500/);
  assert.match(source, /Deferred FTO recheck failed\.[\s\S]*?databaseChanged\},502/);
});

test("active recheck runs heartbeat and stale runs are recovered before a new run", () => {
  assert.match(source, /admin\.rpc\("vbgramg_recover_stale_fto_recheck_runs"/);
  assert.match(source, /admin\.rpc\("vbgramg_heartbeat_fto_recheck_run"/);
  assert.match(source, /for\(const batch of eligible\)[\s\S]*?heartbeatError/);
});

test("recheck pages imported batches, deferred transactions, and stored FTO rows", () => {
  assert.match(source, /const pageSize=500/);
  assert.match(source, /from\("vbgramg_fto_batches"\)[\s\S]*?\.order\("id",\{ascending:true\}\)\.range\(offset,offset\+pageSize-1\)/);
  assert.match(source, /from\("vbgramg_fto_transactions"\)[\s\S]*?\.eq\("status","blank"\)[\s\S]*?\.order\("id",\{ascending:true\}\)\.range\(pageOffset,pageOffset\+pageSize-1\)/);
  assert.match(source, /\.eq\("batch_id",batch\.id\)[\s\S]*?\.order\("id",\{ascending:true\}\)\.range\(pageOffset,pageOffset\+pageSize-1\)/);
  assert.match(source, /if\(!page\|\|page\.length<pageSize\) break/);
});

test("result summaries report eligible, checked, successful, failed, and unprocessed FTO counts", () => {
  for (const field of ["eligibleFtoCount", "checkedFtoCount", "successfulFtoCount", "failedFtoCount", "unprocessedFtoCount"]) {
    assert.match(source, new RegExp(field));
  }
  assert.match(source, /unchangedCount\+=Number\(resultBatch\.unchanged_count\|\|0\)/);
  assert.match(source, /failedCheckCount:failedChecks\.length/);
});

test("an FTO failure counts even when its audit record cannot be saved, and processing stops", () => {
  assert.match(source, /failedFtOs\+\+/);
  assert.match(source, /auditRecorded:false/);
  assert.match(source, /if\(auditPersistenceError\)[\s\S]*?break/);
  assert.match(source, /unprocessedFtoCount=eligibleFtoCount-checkedFtoCount/);
});

test("listing-level and outer errors return consistent summary fields", () => {
  assert.match(source, /unprocessedFtoCount:eligibleFtoCount/);
  assert.match(source, /failedFtoCount:failedFtOs/);
  assert.match(source, /unchangedCount,failedCheckCount:failedChecks\.length/);
});

test("detail parsing is scoped to the Government transaction table and ignores subtotal/total rows", () => {
  assert.ok(source.includes("const transactionTable = [...html.matchAll("));
  assert.ok(source.includes(".map(match => rowsOf(match[1]))"));
  assert.ok(source.includes("transactionTable.slice(transactionTable.indexOf(header)+1)"));
  assert.ok(source.includes("/^(?:sub\\s*total|total)$/i"));
  assert.doesNotMatch(source, /allRows\.slice\(allRows\.indexOf\(header\)\+1\)/);
});
