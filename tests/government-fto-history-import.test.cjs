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

test("Eligibility stores only Active MIS Job Card rows and keeps applicant review rows", () => {
  assert.match(details, /const governmentTransactionCount = transactions\.length/);
  assert.match(details, /transactions\.filter\(tx => !misIndex\.activeCards\.has/);
  assert.match(details, /const matchingTransactions = transactions\.filter\(tx => misIndex\.activeCards\.has/);
  assert.match(details, /importableTransactionCount: matchingTransactions\.length/);
  assert.match(details, /validated_transactions: matchingTransactions/);
  assert.match(details, /unmatched_transaction_count: unmatchedTransactionCount/);
  assert.match(details, /validateGovernmentTransactions\(transactions, item\.listingRow \|\| \[\]\)/);
  assert.doesNotMatch(details, /village.*(?:filter|eligible|scope)/i);
});

test("Government manifest is encrypted, expires, and detail inspection binds to current Active MIS", () => {
  assert.match(fetcher, /exp: Date\.now\(\) \+ 45 \* 60 \* 1000/);
  assert.match(fetcher, /VBGRAMG-FTO-MANIFEST-v1:/);
  assert.match(fetcher, /AES-GCM/);
  assert.match(details, /manifest\.exp < Date\.now\(\)/);
  assert.match(details, /loadActiveMisJobCards\(admin\)/);
  assert.match(details, /misSnapshot: \{ activeImportId: misIndex\.importId, misUpdatedAt: misIndex\.misUpdatedAt \}/);
});test("Import endpoint accepts only signed previews and caps each request", () => {
  assert.match(importer, /body\.ftos\.length > 50/);
  assert.match(importer, /readJsonBody\(req, 10_000_000\)/);
  assert.match(importer, /openImportPreviewToken\(token, serviceKey\)/);
  assert.match(importer, /preview\.governmentTransactionCount/);
  assert.match(importer, /preview\.unmatchedTransactionCount/);
  assert.match(importer, /payload\.governmentTransactionCount !== payload\.rows\.length \+ payload\.unmatchedTransactionCount/);
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

test("Only imported and Out of Scope FTOs are terminal during Government refresh", () => {
  assert.match(details, /matchingCards\.size === 0 \? "OUT_OF_SCOPE" : "ELIGIBLE"/);
  assert.doesNotMatch(details, /COMPLETE/);
  assert.match(details, /classification === "OUT_OF_SCOPE"/);
  assert.doesNotMatch(details, /classification === "ELIGIBLE"\)\s*\{\s*throw new Error/);
  assert.match(fetcher, /const isOutOfScope = \(item: \{ ftoNumber: string \}\)/);
  assert.match(fetcher, /const classificationFor = \(item: \{ ftoNumber: string \}\)/);
  assert.match(fetcher, /classificationFor\(item\) === "OUT_OF_SCOPE"/);
  assert.match(fetcher, /const skippedInspectedFtos = newFtos\.filter\(isOutOfScope\)/);
  assert.match(fetcher, /const alreadyCheckedEligibleFtos = newFtos\.filter\(item => classificationFor\(item\) === "ELIGIBLE"\)/);
  assert.match(fetcher, /const readyToImportFtos = newFtos\.filter\(item => !isOutOfScope\(item\) && classificationFor\(item\) !== "ELIGIBLE"\)/);
  assert.match(fetcher, /alreadyCheckedEligibleFtos/);
  assert.match(fetcher, /alreadyImported/);
  assert.match(fetcher, /previously checked eligible FTOs remain available in Pending Imports/);
  assert.doesNotMatch(fetcher, /Every previously inspected FTO is excluded/);
});test("Frontend inspects Government details in small batches and delegates import to Pending Imports", () => {
  assert.match(page, /pending\.splice\(0,5\)/);
  assert.match(page, /vbgramg-fto-government-details/);
  assert.match(page, /Eligible FTOs will be available in Pending Imports/);
  assert.match(page, /Unmatched rows excluded from storage/);
  assert.match(page, /stored transaction details:/i);
  assert.match(page, /Open this FTO from Pending Imports to complete applicant matching and import/);
  assert.doesNotMatch(page, /Earlier successful requests remain imported/);
});test("Government FTO preview is independent of Contribution exemptions", () => {
  assert.doesNotMatch(details, /vbgramg_contribution_exemptions|exemptCards|contributionExempt/);
});

test("FTO Import uses one entry point and embeds Government refresh in the saved queue", () => {
  const history = read("fto.html");
  const pending = read("pending-imports.html");
  const government = read("fto-government-fetch.html");
  assert.match(history, /id="open-fto-import"[^>]*>FTO Import</);
  assert.doesNotMatch(history, /id="open-pending-imports"/);
  assert.doesNotMatch(history, /id="pending-imports-modal"/);
  assert.match(history, /governmentFrame\.src='\.\/fto-government-fetch\.html\?modal=1'/);
  assert.match(history, /governmentFrame\.src='\.\/pending-imports\.html\?modal=1'/);
  assert.match(history, /startPendingImportInCurrentModal/);
  assert.match(history, /open\.disabled=true/);
  assert.match(history, /open\.textContent='Preparing…'/);
  assert.match(history, /vbgramg-pending-imports-result/);
  assert.match(pending, /notifyParent\(\{status:"success",count:pending\.length\}\)/);
  assert.match(pending, /notifyParent\(\{status:"error",message\}\)/);
  assert.match(pending, /id="refresh-government"/);
  assert.match(pending, /id="government-refresh-frame"/);
  assert.match(pending, /action:"list-pending-ftos"/);
  assert.match(pending, /vbgramg-government-refresh-complete/);
  assert.match(government, /modalMode/);
  assert.match(government, /queueMicrotask\(runGovernmentFetch\)/);
  assert.match(government, /async function runGovernmentFetch\(\)/);
  assert.match(government, /id="details-panel" hidden aria-hidden="true"/);
  assert.doesNotMatch(government, /<h2>Transaction preview<\/h2>|Starting automatic detail checks…|No eligible new FTOs require detail checks/);
  assert.doesNotMatch(government, /Read-only comparison|Refresh Government listing|fetch-button/);
  assert.match(government, /fetch-status.*hidden/);
  assert.match(government, /catch\(error\).*fetch-status.*error/s);
  assert.match(government, /vbgramg-government-refresh-complete/);
  assert.match(government, /id="new-count"/);
  assert.match(government, /Ready to import/);
  assert.match(government, /Already checked — eligible, not imported/);
  assert.match(government, /No FTOs are ready to import\./);
  assert.doesNotMatch(government, /Eligible \/ refreshable FTOs|Needs review|Total listed|Fetched at/);
});

test("Inline scripts in the unified FTO workflow parse cleanly", () => {
  const vm = require("node:vm");
  for (const file of ["fto.html", "pending-imports.html", "fto-government-fetch.html"]) {
    const html = read(file);
    const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
      .map(match => match[1]).filter(source => source.trim());
    assert.ok(scripts.length, file + " should contain inline workflow code");
    for (const [index, source] of scripts.entries()) {
      assert.doesNotThrow(() => new vm.Script(source, { filename: file + " inline script " + index }));
    }
  }
});
