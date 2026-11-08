const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const edge = read("supabase/functions/vbgramg-contribution-data/index.ts");
const migration = read("supabase/migrations/20261107050000_postgres_fto_charge_calculation.sql");
const page = read("fto-import.html");

function section(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `Missing start marker: ${startMarker}`);
  const end = source.indexOf(endMarker, start);
  assert.notEqual(end, -1, `Missing end marker: ${endMarker}`);
  return source.slice(start, end);
}

test("FTO snapshot sends links only for active transactions and checks the committed RPC result", () => {
  const sync = section(edge, 'if(action==="sync-fto-batch"){', 'if(action==="sync-fto-status"){');
  assert.match(sync, /for\s*\(const tx of active\)\s*\{\s*transactionLinks\.push\(\{id:String\(tx\.id\),ledger_entry_id:ledgerId\}\);\s*\}/);
  assert.match(sync, /transaction_links:transactionLinks/);
  assert.match(sync, /admin\.rpc\("vbgramg_apply_fto_snapshot"/);
  assert.match(sync, /if\(!rpcResult\?\.committed\)/);
});

test("PostgreSQL snapshot applies only the transaction links explicitly supplied in its plan", () => {
  const update = migration.indexOf("update public.vbgramg_fto_transactions tx");
  assert.notEqual(update, -1);
  const block = migration.slice(update, update + 650);
  assert.match(block, /set ledger_entry_id = x\.ledger_entry_id, updated_at = now\(\)/i);
  assert.match(block, /jsonb_to_recordset\(coalesce\(p_plan->'transaction_links', '\[\]'::jsonb\)\)/i);
  assert.match(block, /where tx\.id = x\.id/i);
});

test("Post-commit verification detects conflicting non-null links before attempting repair", () => {
  const verify = edge.indexOf("// The atomic snapshot has committed.");
  const catchStart = edge.indexOf("}catch(verificationError){", verify);
  assert.ok(verify >= 0 && catchStart > verify);
  const block = edge.slice(verify, catchStart);
  const conflictCheck = block.indexOf("const conflicts=");
  const repairStart = block.indexOf("const repairsByLedger=");
  assert.ok(conflictCheck >= 0 && repairStart > conflictCheck);
  assert.match(block, /found\.get\(id\)!==null&&found\.get\(id\)!==expectedById\.get\(id\)/);
  assert.match(block, /snapshot_committed:true,link_conflicts:conflicts\.length/);
  assert.match(block, /if\(conflicts\.length\)return reply/);
});

test("Missing links are repaired only when NULL, grouped by expected ledger, and re-verified", () => {
  const verify = edge.indexOf("// The atomic snapshot has committed.");
  const catchStart = edge.indexOf("}catch(verificationError){", verify);
  const block = edge.slice(verify, catchStart);
  assert.match(block, /const missing=ids\.filter\(id=>!found\.has\(id\)\|\|found\.get\(id\)===null\)/);
  assert.match(block, /repairsByLedger\.set\(ledgerId,\[\]\)/);
  assert.match(block, /\.update\(\{ledger_entry_id:ledgerId\}\)\.in\("id",repairIds\)\.is\("ledger_entry_id",null\)/);
  assert.match(block, /const \{data:verifiedRows,error:verifyError\}/);
  assert.match(block, /const unresolved=ids\.filter\(id=>verified\.get\(id\)!==expectedById\.get\(id\)\)/);
  assert.match(block, /snapshot_committed:true,unlinked_transactions:unresolved\.length/);
});

test("Every post-commit verification exception returns an explicit do-not-reimport response", () => {
  const verify = edge.indexOf("// The atomic snapshot has committed.");
  const catchStart = edge.indexOf("}catch(verificationError){", verify);
  const success = edge.indexOf("return reply({approved:true", catchStart);
  assert.ok(verify >= 0 && catchStart > verify && success > catchStart);
  const block = edge.slice(catchStart, success);
  assert.match(block, /snapshot_committed:true/);
  assert.match(block, /Do not re-import this FTO/);
  assert.match(block, /Administrator review is required/);
});

test("FTO import UI preserves committed-failure warning and prevents same-page retry", () => {
  assert.match(page, /snapshot_committed/);
  assert.match(page, /Import committed — review required/);
  assert.match(page, /Do not re-import this FTO/);
});
