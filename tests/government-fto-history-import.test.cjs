const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const details = read("supabase/functions/vbgramg-fto-government-details/index.ts");
const importer = read("supabase/functions/vbgramg-fto-government-import/index.ts");
const fetcher = read("supabase/functions/vbgramg-fto-government-fetch/index.ts");
const migration = read("supabase/migrations/20261117180000_normalize_government_fto_mis_card_match.sql");
const page = read("fto-government-fetch.html");

test("Government detail parser binds every transaction to its parent FTO", () => {
  assert.match(details, /async function getPage\(url: string, ftoNumber: string\)/);
  assert.match(details, /transactions\.push\(\{[\s\S]{0,180}?ftoNumber,/);
  assert.match(details, /getPage\(item\.detailUrl, item\.ftoNumber\)/);
});

test("Eligibility is based on Active MIS Job Card presence and retains every FTO row", () => {
  assert.match(details, /const matchingTransactions = transactions\.filter\(tx => tx\.misMatchStatus !== "not_in_active_mis"\)/);
  assert.match(details, /const matchingCards = new Set\(matchingTransactions\.map/);
  assert.match(details, /importableTransactionCount: transactions\.length/);
  assert.match(details, /rows: transactions/);
  assert.doesNotMatch(details, /village.*(?:filter|eligible|scope)/i);
});

test("Preview tokens are short-lived and bound to administrator and MIS snapshot", () => {
  assert.match(details, /exp:\s*Date\.now\(\)\s*\+\s*15\s*\*\s*60\s*\*\s*1000/);
  assert.match(details, /userId:\s*userId/);
  assert.match(importer, /preview\.userId !== claims\.sub/);
  assert.match(importer, /preview\.ftoNumber\.trim\(\)\.toUpperCase\(\) !== number/);
  assert.match(importer, /preview\.activeImportId !== activeImportId/);
  assert.match(importer, /preview\.misUpdatedAt !== misUpdatedAt/);
});

test("Import endpoint accepts only signed previews and caps each request", () => {
  assert.match(importer, /body\.ftos\.length > 50/);
  assert.match(importer, /readJsonBody\(req, 10_000_000\)/);
  assert.match(importer, /openImportPreviewToken\(token, serviceKey\)/);
  assert.match(importer, /admin\.rpc\("vbgramg_import_government_fto_history"/);
  assert.doesNotMatch(importer, /body\.ftos\[[^\]]+\]\.rows/);
});

test("SQL import RPC is service-role-only and keeps Government history separate from Contribution", () => {
  assert.match(migration, /security definer\s+set search_path = ''/i);
  assert.match(migration, /revoke all on function public\.vbgramg_import_government_fto_history[\s\S]*?from public, anon, authenticated/i);
  assert.match(migration, /grant execute on function public\.vbgramg_import_government_fto_history[\s\S]*?to service_role/i);
  assert.match(migration, /alter column contribution_period drop not null/i);
  assert.match(migration, /alter column village_scope drop not null/i);
  assert.match(migration, /v_fto_number, null, null, null,/);
  assert.match(migration, /calculated_charge, status, rejection_reason, ledger_entry_id, source_row/);
  assert.match(migration, /null, v_status, v_reason, null, v_source_row/);
  assert.doesNotMatch(migration, /insert\s+into\s+public\.vbgramg_charge_ledger/i);
  assert.doesNotMatch(migration, /insert\s+into\s+public\.vbgramg_payment_allocations/i);
});

test("SQL independently validates normalized Active MIS matching and duplicate protection", () => {
  assert.match(migration, /upper\(btrim\(coalesce\(m\.row_data->>v_job_card_col, ''\)\)\) = upper\(btrim\(v_card\)\)/i);
  assert.match(migration, /upper\(btrim\(b\.fto_number\)\) = upper\(v_fto_number\)/i);
  assert.match(migration, /v_reference = any\(v_seen_refs\)/i);
  assert.match(migration, /if not v_fto_has_active_mis_match then/i);
});

test("Fetcher permanently excludes imported and out-of-scope FTOs without Deferred rechecks", () => {
  assert.match(fetcher, /classification === "OUT_OF_SCOPE"/);
  assert.match(fetcher, /imported/);
  assert.doesNotMatch(fetcher, /RECHECK_REQUIRED|deferredNumbers|deferredFtos/);
});

test("Frontend chunks by FTO count and byte size, and warns about partial completion", () => {
  assert.match(page, /candidate\.length>50/);
  assert.match(page, /maxBytes=8_000_000/);
  assert.match(page, /Earlier successful requests remain imported/);
  assert.match(page, /Unmatched rows included for later review/);
  assert.match(page, /refresh the Government listing and FTO History before attempting another import/i);
});
