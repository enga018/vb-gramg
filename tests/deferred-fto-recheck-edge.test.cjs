const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const source = fs.readFileSync(path.join(__dirname, "..", "supabase/functions/vbgramg-fto-deferred-recheck/index.ts"), "utf8");

test("deferred recheck is isolated from the initial import endpoints", () => {
  assert.match(source, /vbgramg_recheck_deferred_ftos/);
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
  assert.match(source, /async function fetchDetail\\(url: string, ftoNumber: string, listingRow: string\\[\\]\\)/);
  assert.match(source, /fetchDetail\\(candidate\\.url,ftoNumber,candidate\\.row\\)/);
  assert.doesNotMatch(source, /fetchDetail as any/);
});

test("recheck RPC receives only existing references and never calls an insert path", () => {
  assert.match(source, /storedByRef/);
  assert.match(source, /admin\.rpc\("vbgramg_recheck_deferred_ftos"/);
  assert.doesNotMatch(source, /\.insert\(/);
  assert.doesNotMatch(source, /vbgramg_import_government_fto_history/);
});

test("per-FTO failures are isolated and reported", () => {
  assert.match(source, /failedChecks\.push/);
  assert.match(source, /failedCheckCount/);
  assert.match(source, /data\?\.batches\?\.\[0\]\?\.result/);
});
