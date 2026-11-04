const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

const sourcePath = path.join(__dirname, "../js/data-loader.js");

function loadDataLoader(client, windowOverrides = {}) {
  const window = {
    VBGRAMG_SUPABASE_READY: Promise.resolve(client),
    setTimeout,
    clearTimeout,
    ...windowOverrides
  };
  vm.runInNewContext(fs.readFileSync(sourcePath, "utf8"), { window }, { filename: sourcePath });
  return window.VBGRAMGData;
}

test("shared loader exposes request and Supabase-compatible invoke APIs", async () => {
  const data = { ok: true };
  const loader = loadDataLoader({
    functions: { invoke: async () => ({ data, error: null }) }
  });

  assert.deepEqual(await loader.request("read-data"), data);
  const response = await loader.invoke("read-data");
  assert.equal(response.data.ok, true);
  assert.equal(response.error, null);
});

test("identical opted-in reads share one in-flight request", async () => {
  let calls = 0;
  let resolveRequest;
  const pending = new Promise(resolve => { resolveRequest = resolve; });
  const loader = loadDataLoader({
    functions: {
      invoke: () => {
        calls += 1;
        return pending;
      }
    }
  });

  const first = loader.request("read-data", { body: { page: 1 }, deduplicate: true });
  const second = loader.request("read-data", { body: { page: 1 }, deduplicate: true });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls, 1);

  resolveRequest({ data: { rows: [1] }, error: null });
  assert.deepEqual(await first, { rows: [1] });
  assert.deepEqual(await second, { rows: [1] });
});

test("requests are not deduplicated unless explicitly opted in", async () => {
  let calls = 0;
  const loader = loadDataLoader({
    functions: {
      invoke: async () => ({ data: { call: ++calls }, error: null })
    }
  });

  const first = await loader.request("write-data", { body: { amount: 100 } });
  const second = await loader.request("write-data", { body: { amount: 100 } });
  assert.equal(first.call, 1);
  assert.equal(second.call, 2);
});

test("write requests can preserve no-timeout behavior", async () => {
  let timerCalls = 0;
  const loader = loadDataLoader({
    functions: {
      invoke: async () => ({ data: { saved: true }, error: null })
    }
  }, {
    setTimeout: () => {
      timerCalls += 1;
      throw new Error("A timeout should not be scheduled for this write.");
    }
  });

  const response = await loader.invoke("save-data", {
    body: { amount: 100 },
    timeoutMs: false
  });
  assert.equal(response.data.saved, true);
  assert.equal(response.error, null);
  assert.equal(timerCalls, 0);
});

test("invoke preserves Supabase error context", async () => {
  const originalError = { message: "Request failed", context: { status: 400 } };
  const loader = loadDataLoader({
    functions: { invoke: async () => ({ data: null, error: originalError }) }
  });

  const response = await loader.invoke("read-data");
  assert.equal(response.data, null);
  assert.equal(response.error, originalError);
});

test("request timeout is applied to reads", async () => {
  const loader = loadDataLoader({
    functions: { invoke: () => new Promise(() => {}) }
  });

  await assert.rejects(
    loader.request("slow-read", { timeoutMs: 5 }),
    /slow-read request timed out after 0 seconds/
  );
});
