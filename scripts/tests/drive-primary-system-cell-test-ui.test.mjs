import assert from "node:assert/strict";
import test from "node:test";

import {
  drivePrimarySystemCellTestUi,
  ensurePrimarySystemCellProjectionOwner,
  parseArgs,
} from "../drive-primary-system-cell-test-ui.mjs";

const TARGET = Object.freeze({
  type: "page",
  url: "http://127.0.0.1:3000/projection-visual/",
  webSocketDebuggerUrl: "ws://127.0.0.1:9222/devtools/page/opaque",
});

function fakeFetch(targets = [TARGET]) {
  return async () => ({ ok: true, text: async () => JSON.stringify(targets) });
}

function preparingFetch({ initialTargets = [], finalTargets = [TARGET], createOk = true } = {}) {
  const calls = [];
  let created = false;
  return {
    fetchImpl: async (url, options = {}) => {
      calls.push({ url: String(url), method: options.method ?? "GET" });
      if (options.method === "PUT") {
        created = true;
        return {
          ok: createOk,
          text: async () => JSON.stringify({ type: "page" }),
        };
      }
      return {
        ok: true,
        text: async () => JSON.stringify(created ? finalTargets : initialTargets),
      };
    },
    calls,
  };
}

function fakeSession({ inputReady = true, dispatched = true, closeFails = false } = {}) {
  const operations = [];
  let armCount = 0;
  let closeCount = 0;
  return {
    arm: async () => { armCount += 1; },
    prepareFixedVoiceTestInput: async () => {
      operations.push("prepare_fixed_voice_test_input");
      return { inputReady };
    },
    dispatchFixedVoiceTestInput: async () => {
      operations.push("dispatch_fixed_voice_test_input");
      return { dispatched };
    },
    close: async () => {
      closeCount += 1;
      if (closeFails) throw new Error("private cleanup detail");
    },
    stats: () => ({ armCount, closeCount, operations }),
  };
}

function assertFixedOutput(result) {
  assert.deepEqual(Object.keys(result), [
    "schema_version",
    "result_class",
    "ui_dispatch_count",
    "elapsed_ms",
    "cleanup_class",
    "raw_private_publication_flags",
  ]);
  const serialized = JSON.stringify(result);
  assert.equal(result.raw_private_publication_flags, false);
  assert.equal(serialized.includes("音声重なり"), false);
  assert.equal(serialized.includes("projection-visual"), false);
  assert.equal(serialized.includes("devtools"), false);
  assert.equal(serialized.includes("private cleanup detail"), false);
}

test("dispatches one fixed non-device test prompt through the owner page", async () => {
  const session = fakeSession();
  const result = await drivePrimarySystemCellTestUi({
    cdpEndpoint: "http://127.0.0.1:9222/",
    fetchImpl: fakeFetch(),
    connectImpl: async () => session,
    now: () => 1_000,
    sleep: async () => {},
  });
  assert.equal(result.result_class, "test_ui_seed_dispatched");
  assert.equal(result.ui_dispatch_count, 1);
  assert.equal(result.cleanup_class, "cdp_session_released");
  const stats = session.stats();
  assert.equal(stats.armCount, 1);
  assert.equal(stats.closeCount, 1);
  assert.deepEqual(stats.operations, [
    "prepare_fixed_voice_test_input",
    "dispatch_fixed_voice_test_input",
  ]);
  assertFixedOutput(result);
});

test("fails closed for missing, ambiguous, and rejected owner UI", async (t) => {
  const cases = [
    { name: "missing", targets: [], expected: "projection_owner_page_missing" },
    { name: "multiple", targets: [TARGET, { ...TARGET }], expected: "projection_owner_page_multiple" },
    { name: "input", targets: [TARGET], session: fakeSession({ inputReady: false }), expected: "test_ui_input_unavailable" },
    { name: "dispatch", targets: [TARGET], session: fakeSession({ dispatched: false }), expected: "test_ui_dispatch_rejected" },
  ];
  for (const entry of cases) {
    await t.test(entry.name, async () => {
      const session = entry.session ?? fakeSession();
      const result = await drivePrimarySystemCellTestUi({
        cdpEndpoint: "http://localhost:9222/",
        fetchImpl: fakeFetch(entry.targets),
        connectImpl: async () => session,
        sleep: async () => {},
      });
      assert.equal(result.result_class, entry.expected);
      assert.equal(result.ui_dispatch_count, 0);
      assertFixedOutput(result);
    });
  }
});

test("cleanup failure replaces a successful dispatch", async () => {
  const result = await drivePrimarySystemCellTestUi({
    cdpEndpoint: "http://127.0.0.1:9222/",
    fetchImpl: fakeFetch(),
    connectImpl: async () => fakeSession({ closeFails: true }),
    sleep: async () => {},
  });
  assert.equal(result.result_class, "test_ui_cleanup_incomplete");
  assert.equal(result.cleanup_class, "test_ui_cleanup_incomplete");
  assertFixedOutput(result);
});

test("prepares exactly one fixed projection owner without an arbitrary URL surface", async () => {
  const prepared = preparingFetch();
  const result = await ensurePrimarySystemCellProjectionOwner({
    cdpEndpoint: "http://127.0.0.1:9222/",
    fetchImpl: prepared.fetchImpl,
    now: () => 1_000,
    sleep: async () => {},
  });
  assert.equal(result.result_class, "projection_owner_created");
  assert.equal(result.ui_dispatch_count, 0);
  assert.deepEqual(prepared.calls.map(({ method }) => method), ["GET", "PUT", "GET"]);
  assert.equal(prepared.calls[1].url, "http://127.0.0.1:9222/json/new?http://127.0.0.1:3000/projection-visual/");
  assertFixedOutput(result);
});

test("owner preparation is idempotent and fails closed for ambiguity or create failure", async (t) => {
  await t.test("existing owner", async () => {
    const prepared = preparingFetch({ initialTargets: [TARGET] });
    const result = await ensurePrimarySystemCellProjectionOwner({
      cdpEndpoint: "http://localhost:9222/",
      fetchImpl: prepared.fetchImpl,
    });
    assert.equal(result.result_class, "projection_owner_ready");
    assert.deepEqual(prepared.calls.map(({ method }) => method), ["GET"]);
    assertFixedOutput(result);
  });
  await t.test("ambiguous owner", async () => {
    const prepared = preparingFetch({ initialTargets: [TARGET, { ...TARGET }] });
    const result = await ensurePrimarySystemCellProjectionOwner({
      cdpEndpoint: "http://127.0.0.1:9222/",
      fetchImpl: prepared.fetchImpl,
    });
    assert.equal(result.result_class, "projection_owner_page_multiple");
    assert.deepEqual(prepared.calls.map(({ method }) => method), ["GET"]);
    assertFixedOutput(result);
  });
  await t.test("wrong loopback origin", async () => {
    const wrongOrigin = {
      ...TARGET,
      url: "http://127.0.0.1:3999/projection-visual/",
    };
    const prepared = preparingFetch({ initialTargets: [wrongOrigin] });
    const result = await ensurePrimarySystemCellProjectionOwner({
      cdpEndpoint: "http://127.0.0.1:9222/",
      fetchImpl: prepared.fetchImpl,
    });
    assert.equal(result.result_class, "projection_owner_target_invalid");
    assert.deepEqual(prepared.calls.map(({ method }) => method), ["GET"]);
    assertFixedOutput(result);
  });
  await t.test("create rejected", async () => {
    const prepared = preparingFetch({ createOk: false });
    const result = await ensurePrimarySystemCellProjectionOwner({
      cdpEndpoint: "http://127.0.0.1:9222/",
      fetchImpl: prepared.fetchImpl,
    });
    assert.equal(result.result_class, "projection_owner_target_create_failed");
    assert.deepEqual(prepared.calls.map(({ method }) => method), ["GET", "PUT"]);
    assertFixedOutput(result);
  });
});

test("owner preparation shares one advancing-clock deadline", async () => {
  const prepared = preparingFetch();
  let currentTime = 0;
  const result = await ensurePrimarySystemCellProjectionOwner({
    cdpEndpoint: "http://127.0.0.1:9222/",
    timeoutMs: 500,
    fetchImpl: prepared.fetchImpl,
    now: () => {
      currentTime += 300;
      return currentTime;
    },
    sleep: async () => {},
  });
  assert.equal(result.result_class, "projection_owner_prepare_timeout");
  assert.deepEqual(prepared.calls.map(({ method }) => method), ["GET"]);
  assertFixedOutput(result);
});

test("dispatch rejects a unique wrong-port Projection path before CDP", async () => {
  let connectCount = 0;
  const result = await drivePrimarySystemCellTestUi({
    cdpEndpoint: "http://127.0.0.1:9222/",
    fetchImpl: fakeFetch([{
      ...TARGET,
      url: "http://localhost:3999/projection-visual/",
    }]),
    connectImpl: async () => {
      connectCount += 1;
      return fakeSession();
    },
  });
  assert.equal(result.result_class, "projection_owner_target_invalid");
  assert.equal(connectCount, 0);
  assertFixedOutput(result);
});

test("arguments expose no prompt or arbitrary expression surface", () => {
  assert.deepEqual(
    parseArgs(["--cdp-endpoint", "http://127.0.0.1:9222", "--timeout-ms", "800"]),
    { cdpEndpoint: "http://127.0.0.1:9222", timeoutMs: 800, prepareOwner: false },
  );
  assert.deepEqual(
    parseArgs(["--prepare-owner", "--cdp-endpoint", "http://127.0.0.1:9222"]),
    { cdpEndpoint: "http://127.0.0.1:9222", timeoutMs: 5_000, prepareOwner: true },
  );
  assert.throws(() => parseArgs(["--prompt", "private"]), /test_ui_configuration_invalid/u);
  assert.throws(() => parseArgs(["--expression", "arbitrary"]), /test_ui_configuration_invalid/u);
  assert.throws(() => parseArgs(["--projection-url", "http://private.invalid"]), /test_ui_configuration_invalid/u);
});
