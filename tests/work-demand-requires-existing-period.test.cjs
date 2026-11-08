const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const handler = fs.readFileSync(
  path.join(__dirname, "../supabase/functions/vbgramg-demand-runs/index.ts"),
  "utf8"
);

test("Work Demand rejects requests without an existing period ID", () => {
  assert.match(handler, /const periodId = textValue\(body\.periodId, 64\);[\s\S]*?if \(!periodId\)[\s\S]*?return reply\(req, \{ error: "Select an existing open period\./);
});

test("Work Demand verifies the selected period exists and is open", () => {
  assert.match(handler, /from\("vbgramg_periods"\)[\s\S]*?\.eq\("id", periodId\)[\s\S]*?\.maybeSingle\(\)/);
  assert.match(handler, /if \(!period \|\| period\.status !== "open"\)/);
});

test("Work Demand endpoint cannot create or delete periods", () => {
  assert.doesNotMatch(handler, /from\("vbgramg_periods"\)\s*\.insert\(/);
  assert.doesNotMatch(handler, /from\("vbgramg_periods"\)\s*\.delete\(/);
  assert.doesNotMatch(handler, /createdPeriodId|compactMonthName|createPeriodError/);
});
