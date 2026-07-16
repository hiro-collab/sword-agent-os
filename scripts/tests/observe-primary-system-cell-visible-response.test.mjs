import assert from "node:assert/strict";
import test from "node:test";

import {
  connectCdp,
  fixedOwnerPageReloadRequired,
  observeVisibleResponse,
  parseArgs,
  selectProjectionVisualTarget,
} from "../observe-primary-system-cell-visible-response.mjs";

const TARGET = Object.freeze({
  type: "page",
  url: "http://127.0.0.1:3000/projection-visual/",
  webSocketDebuggerUrl: "ws://127.0.0.1:9222/devtools/page/opaque",
});

function fakeFetch(targets = [TARGET], ok = true) {
  return async () => ({ ok, json: async () => targets });
}

function clock(start = 1_000) {
  let current = start;
  const observedAtWallMs = Date.parse("2026-07-15T00:00:00.000Z");
  return {
    now: () => current,
    wallNowMs: () => observedAtWallMs,
    sleep: async (milliseconds) => { current += milliseconds; },
  };
}

function fakeSession(counts, { closeFails = false } = {}) {
  let index = 0;
  let armCount = 0;
  let closeCount = 0;
  return {
    arm: async () => { armCount += 1; },
    inspect: async () => counts[Math.min(index++, counts.length - 1)],
    close: async () => {
      closeCount += 1;
      if (closeFails) throw new Error("private close detail");
      assert.equal(closeCount, 1);
    },
    getArmCount: () => armCount,
    getCloseCount: () => closeCount,
  };
}

function assertFixedOutputShape(result) {
  assert.deepEqual(Object.keys(result), [
    "schema_version",
    "result_class",
    "visible_match_count",
    "observed_at_wall",
    "observer_elapsed_ms",
    "cleanup_class",
    "raw_private_publication_flags",
  ]);
  assert.equal(result.raw_private_publication_flags, false);
  assert.equal(JSON.stringify(result).includes("private"), true);
  assert.equal(JSON.stringify(result).includes("private close detail"), false);
  assert.equal(JSON.stringify(result).includes("projection-visual"), false);
  assert.equal(JSON.stringify(result).includes("devtools"), false);
}

test("selects exactly one loopback Projection Visual owner page", () => {
  assert.equal(selectProjectionVisualTarget([TARGET]), TARGET);
  assert.throws(
    () => selectProjectionVisualTarget([]),
    (error) => error.message === "projection_owner_page_missing",
  );
  assert.throws(
    () => selectProjectionVisualTarget([TARGET, { ...TARGET }]),
    (error) => error.message === "projection_owner_page_multiple",
  );
  assert.throws(
    () => selectProjectionVisualTarget([{ ...TARGET, webSocketDebuggerUrl: "ws://example.com/devtools/page/1" }]),
    (error) => error.message === "projection_owner_target_invalid",
  );
});

test("requests a fixed owner reload only for a complete empty Projection document", () => {
  assert.equal(fixedOwnerPageReloadRequired({
    documentReadyState: "loading",
    projectionRootPresent: false,
    textareaPresent: false,
  }), false);
  assert.equal(fixedOwnerPageReloadRequired({
    documentReadyState: "complete",
    projectionRootPresent: true,
    textareaPresent: false,
  }), false);
  assert.equal(fixedOwnerPageReloadRequired({
    documentReadyState: "complete",
    projectionRootPresent: false,
    textareaPresent: true,
  }), false);
  assert.equal(fixedOwnerPageReloadRequired({
    documentReadyState: "complete",
    projectionRootPresent: false,
    textareaPresent: false,
  }), true);
});

test("observes one new visible message without returning content or endpoints", async () => {
  const time = clock();
  const observedAtWallMs = Date.parse("2026-07-15T00:00:00.000Z");
  const session = fakeSession([
    { initialMatchCount: 0, maximumVisibleMatchCount: 0, firstObservedAtWallMs: null },
    {
      initialMatchCount: 0,
      maximumVisibleMatchCount: 0,
      firstObservedAtWallMs: null,
      text: "must-not-escape",
      url: "http://private.invalid",
    },
    {
      initialMatchCount: 0,
      maximumVisibleMatchCount: 1,
      firstObservedAtWallMs: observedAtWallMs,
      arbitrary: { provider_payload: "must-not-escape" },
    },
  ]);
  const inspectedIds = [];
  const originalInspect = session.inspect;
  session.inspect = async (messageId) => {
    inspectedIds.push(messageId);
    return originalInspect();
  };
  const result = await observeVisibleResponse({
    cdpEndpoint: "http://127.0.0.1:9222",
    messageId: "conversation-opaque.1",
    timeoutMs: 500,
    fetchImpl: fakeFetch(),
    connectImpl: async () => session,
    ...time,
  });
  assert.equal(result.result_class, "visible_response_observed");
  assert.equal(result.visible_match_count, 1);
  assert.equal(result.observed_at_wall, "2026-07-15T00:00:00.000Z");
  assert.equal(result.cleanup_class, "observer_socket_released");
  assert.equal(session.getArmCount(), 1);
  assert.equal(session.getCloseCount(), 1);
  assert.deepEqual(inspectedIds, [
    "conversation-opaque.1",
    "conversation-opaque.1",
    "conversation-opaque.1",
  ]);
  assert.equal(JSON.stringify(result).includes("must-not-escape"), false);
  assertFixedOutputShape(result);
});

test("fails closed for stale initial, duplicate, and timeout evidence", async (t) => {
  const cases = [
    [[{
      initialMatchCount: 1,
      maximumVisibleMatchCount: 1,
      firstObservedAtWallMs: null,
    }], "visible_response_stale_initial_match", 0],
    [[{
      initialMatchCount: 0,
      maximumVisibleMatchCount: 2,
      firstObservedAtWallMs: Date.parse("2026-07-15T00:00:00.000Z"),
    }], "visible_response_duplicate", 2],
    [[{
      initialMatchCount: 0,
      maximumVisibleMatchCount: 0,
      firstObservedAtWallMs: null,
    }], "visible_response_timeout", 0],
    [[{
      initialMatchCount: 0,
      maximumVisibleMatchCount: 1,
      firstObservedAtWallMs: 0,
    }], "cdp_observation_invalid", 0],
  ];
  for (const [counts, expectedClass, expectedCount] of cases) {
    await t.test(expectedClass, async () => {
      const time = clock();
      const result = await observeVisibleResponse({
        cdpEndpoint: "http://localhost:9222/",
        messageId: "opaque-2",
        timeoutMs: 100,
        fetchImpl: fakeFetch(),
        connectImpl: async () => fakeSession(counts),
        ...time,
      });
      assert.equal(result.result_class, expectedClass);
      assert.equal(result.visible_match_count, expectedCount);
      assert.equal(result.cleanup_class, "observer_socket_released");
      assertFixedOutputShape(result);
    });
  }
});

test("rejects non-loopback endpoints, unsafe ids, ambiguous owners, and unavailable CDP", async (t) => {
  const cases = [
    [{ cdpEndpoint: "http://example.com:9222", messageId: "safe" }, "invalid_request"],
    [{ cdpEndpoint: "http://127.0.0.1:9222", messageId: "unsafe id" }, "invalid_request"],
    [{ cdpEndpoint: "http://127.0.0.1:9222", messageId: "safe", fetchImpl: fakeFetch([]) }, "projection_owner_page_missing"],
    [{ cdpEndpoint: "http://127.0.0.1:9222", messageId: "safe", fetchImpl: fakeFetch([TARGET, { ...TARGET }]) }, "projection_owner_page_multiple"],
    [{ cdpEndpoint: "http://127.0.0.1:9222", messageId: "safe", fetchImpl: fakeFetch([], false) }, "cdp_endpoint_unavailable"],
  ];
  for (const [input, expectedClass] of cases) {
    await t.test(expectedClass, async () => {
      const result = await observeVisibleResponse({
        timeoutMs: 100,
        fetchImpl: fakeFetch(),
        ...clock(),
        ...input,
      });
      assert.equal(result.result_class, expectedClass);
      assertFixedOutputShape(result);
    });
  }
});

test("cleanup failure overrides an otherwise successful observation", async () => {
  const result = await observeVisibleResponse({
    cdpEndpoint: "http://127.0.0.1:9222",
    messageId: "safe",
    timeoutMs: 100,
    fetchImpl: fakeFetch(),
    connectImpl: async () => fakeSession(
      [{
        initialMatchCount: 0,
        maximumVisibleMatchCount: 1,
        firstObservedAtWallMs: Date.parse("2026-07-15T00:00:00.000Z"),
      }],
      { closeFails: true },
    ),
    ...clock(),
  });
  assert.equal(result.result_class, "observer_cleanup_incomplete");
  assert.equal(result.cleanup_class, "observer_cleanup_incomplete");
  assertFixedOutputShape(result);
});

test("argument parser accepts only the bounded observer inputs", () => {
  assert.deepEqual(
    parseArgs(["--cdp-endpoint", "http://127.0.0.1:9222", "--message-id", "id", "--timeout-ms", "500"]),
    {
      cdpEndpoint: "http://127.0.0.1:9222",
      messageId: "id",
      messageIdStdin: false,
      timeoutMs: 500,
    },
  );
  assert.deepEqual(
    parseArgs(["--cdp-endpoint", "http://127.0.0.1:9222", "--message-id-stdin"]),
    {
      cdpEndpoint: "http://127.0.0.1:9222",
      messageId: null,
      messageIdStdin: true,
      timeoutMs: 10_000,
    },
  );
  assert.throws(() => parseArgs(["--unknown"]), (error) => error.message === "invalid_request");
});

test("arms before obtaining the process-local expected message id", async () => {
  const time = clock();
  let armed = false;
  const session = fakeSession([{
    initialMatchCount: 0,
    maximumVisibleMatchCount: 1,
    firstObservedAtWallMs: Date.parse("2026-07-15T00:00:00.000Z"),
  }]);
  const result = await observeVisibleResponse({
    cdpEndpoint: "http://127.0.0.1:9222",
    messageIdProvider: async () => {
      assert.equal(armed, true);
      return "late-bound-message-id";
    },
    timeoutMs: 100,
    fetchImpl: fakeFetch(),
    connectImpl: async () => session,
    onArmed: async () => { armed = true; },
    ...time,
  });
  assert.equal(result.result_class, "visible_response_observed");
  assert.equal(session.getArmCount(), 1);
  assert.equal(session.getCloseCount(), 1);
});

test("a missing late-bound message id times out and releases the armed session", async () => {
  const session = fakeSession([{
    initialMatchCount: 0,
    maximumVisibleMatchCount: 0,
    firstObservedAtWallMs: null,
  }]);
  const started = Date.now();
  const result = await observeVisibleResponse({
    cdpEndpoint: "http://127.0.0.1:9222",
    messageIdProvider: async () => new Promise(() => {}),
    timeoutMs: 100,
    fetchImpl: fakeFetch(),
    connectImpl: async () => session,
  });
  assert.equal(result.result_class, "visible_response_expected_id_timeout");
  assert.equal(result.cleanup_class, "observer_socket_released");
  assert.equal(session.getArmCount(), 1);
  assert.equal(session.getCloseCount(), 1);
  assert.ok(Date.now() - started < 500);
  assertFixedOutputShape(result);
});

test("CDP client injects only the bounded observer and never closes the browser or page", async () => {
  class FakeWebSocket {
    static OPEN = 1;
    static CLOSED = 3;

    constructor() {
      this.readyState = FakeWebSocket.OPEN;
      this.listeners = new Map();
      this.sent = [];
      FakeWebSocket.instance = this;
      queueMicrotask(() => this.emit("open", {}));
    }

    addEventListener(name, callback, options = {}) {
      const listeners = this.listeners.get(name) ?? [];
      listeners.push({ callback, once: options.once === true });
      this.listeners.set(name, listeners);
    }

    emit(name, event) {
      const listeners = [...(this.listeners.get(name) ?? [])];
      this.listeners.set(name, listeners.filter((listener) => !listener.once));
      for (const listener of listeners) listener.callback(event);
    }

    send(serialized) {
      const request = JSON.parse(serialized);
      this.sent.push(request);
      let value = {};
      if (request.method === "Runtime.evaluate") {
        if (request.params.expression.includes("return { armed: true }")) value = { armed: true };
        else if (request.params.expression.includes("state.observer.disconnect")) value = { cleaned: true };
        else if (request.params.expression.includes("家電は操作せず")) {
          value = { inputReady: true, pageReloadRequired: false };
        }
        else if (request.params.expression.includes("Object.defineProperty")) {
          value = { marked: true };
        }
        else if (request.params.expression.includes("reloadComplete")) {
          value = { reloadComplete: true };
        }
        else if (request.params.expression.includes("KeyboardEvent")) value = { dispatched: true };
        else {
          value = {
            initialMatchCount: 0,
            maximumVisibleMatchCount: 1,
            firstObservedAtWallMs: Date.parse("2026-07-15T00:00:00.000Z"),
          };
        }
      }
      queueMicrotask(() => this.emit("message", {
        data: JSON.stringify({ id: request.id, result: { result: { value } } }),
      }));
    }

    close() {
      this.readyState = FakeWebSocket.CLOSED;
      queueMicrotask(() => this.emit("close", {}));
    }
  }

  const session = await connectCdp(
    "ws://127.0.0.1:9222/devtools/page/opaque",
    { WebSocketImpl: FakeWebSocket, timeoutMs: 100 },
  );
  await session.arm();
  assert.equal(session.evaluate, undefined);
  const prepared = await session.prepareFixedVoiceTestInput();
  await session.reloadFixedOwner();
  const reloadState = await session.isFixedOwnerReloadComplete();
  const dispatched = await session.dispatchFixedVoiceTestInput();
  const inspection = await session.inspect("safe-message-id");
  await session.close();

  assert.deepEqual(prepared, { inputReady: true, pageReloadRequired: false });
  assert.deepEqual(reloadState, { reloadComplete: true });
  assert.deepEqual(dispatched, { dispatched: true });
  assert.equal(inspection.maximumVisibleMatchCount, 1);
  const requests = FakeWebSocket.instance.sent;
  const methods = requests.map((request) => request.method);
  assert.deepEqual(methods, [
    "Runtime.enable",
    "Runtime.evaluate",
    "Runtime.evaluate",
    "Runtime.evaluate",
    "Page.reload",
    "Runtime.evaluate",
    "Runtime.evaluate",
    "Runtime.evaluate",
    "Runtime.evaluate",
  ]);
  assert.equal(requests[3].method, "Runtime.evaluate");
  assert.equal(requests[3].params.expression.includes("Object.defineProperty"), true);
  assert.deepEqual(requests[4], {
    id: 5,
    method: "Page.reload",
    params: {},
  });
  assert.equal(methods.includes("Browser.close"), false);
  assert.equal(methods.includes("Page.close"), false);
  assert.equal(FakeWebSocket.instance.readyState, FakeWebSocket.CLOSED);
});

test("reload completion CDP errors and timeouts fail closed without leaking details", async (t) => {
  for (const mode of ["error", "timeout"]) {
    await t.test(mode, async () => {
      class ReloadTransitionWebSocket {
        static OPEN = 1;
        static CLOSED = 3;

        constructor() {
          this.readyState = ReloadTransitionWebSocket.OPEN;
          this.listeners = new Map();
          this.closeCount = 0;
          ReloadTransitionWebSocket.instance = this;
          queueMicrotask(() => this.emit("open", {}));
        }

        addEventListener(name, callback, options = {}) {
          const listeners = this.listeners.get(name) ?? [];
          listeners.push({ callback, once: options.once === true });
          this.listeners.set(name, listeners);
        }

        emit(name, event) {
          const listeners = [...(this.listeners.get(name) ?? [])];
          this.listeners.set(name, listeners.filter((listener) => !listener.once));
          for (const listener of listeners) listener.callback(event);
        }

        send(serialized) {
          const request = JSON.parse(serialized);
          if (
            request.method === "Runtime.evaluate" &&
            request.params.expression.includes("reloadComplete")
          ) {
            if (mode === "timeout") return;
            queueMicrotask(() => this.emit("message", {
              data: JSON.stringify({
                id: request.id,
                error: {
                  message: "private execution context detail",
                  data: "ws://private.invalid",
                },
              }),
            }));
            return;
          }
          let value = {};
          if (
            request.method === "Runtime.evaluate" &&
            request.params.expression.includes("Object.defineProperty")
          ) {
            value = { marked: true };
          }
          queueMicrotask(() => this.emit("message", {
            data: JSON.stringify({ id: request.id, result: { result: { value } } }),
          }));
        }

        close() {
          this.closeCount += 1;
          this.readyState = ReloadTransitionWebSocket.CLOSED;
          queueMicrotask(() => this.emit("close", {}));
        }
      }

      const session = await connectCdp(
        "ws://127.0.0.1:9222/devtools/page/opaque",
        { WebSocketImpl: ReloadTransitionWebSocket, timeoutMs: 20 },
      );
      await session.reloadFixedOwner();
      const completion = await session.isFixedOwnerReloadComplete();
      await session.close();
      assert.deepEqual(completion, { reloadComplete: false });
      assert.equal(ReloadTransitionWebSocket.instance.closeCount, 1);
      assert.equal(JSON.stringify(completion).includes("private"), false);
    });
  }
});

test("CDP close returns fixed cleanup classes and always attempts one socket close", async (t) => {
  for (const mode of [
    "unarmed",
    "arm_response_lost",
    "page_command",
    "page_state",
    "socket",
    "page_command_socket",
  ]) {
    await t.test(mode, async () => {
      class CleanupWebSocket {
        static OPEN = 1;
        static CLOSING = 2;
        static CLOSED = 3;

        constructor() {
          CleanupWebSocket.instance = this;
          this.readyState = CleanupWebSocket.OPEN;
          this.listeners = new Map();
          this.closeCount = 0;
          this.sentMethods = [];
          queueMicrotask(() => this.emit("open", {}));
        }

        addEventListener(name, callback, options = {}) {
          const listeners = this.listeners.get(name) ?? [];
          listeners.push({ callback, once: options.once === true });
          this.listeners.set(name, listeners);
        }

        emit(name, event) {
          const listeners = [...(this.listeners.get(name) ?? [])];
          this.listeners.set(name, listeners.filter((listener) => !listener.once));
          for (const listener of listeners) listener.callback(event);
        }

        send(serialized) {
          const request = JSON.parse(serialized);
          this.sentMethods.push(request.method);
          if (
            mode === "arm_response_lost" &&
            request.method === "Runtime.evaluate" &&
            request.params.expression.includes("return { armed: true }")
          ) {
            return;
          }
          if (
            mode.startsWith("page_command") &&
            request.method === "Runtime.evaluate" &&
            request.params.expression.includes("state.observer.disconnect")
          ) {
            return;
          }
          let value = {};
          if (request.method === "Runtime.evaluate") {
            if (request.params.expression.includes("return { armed: true }")) {
              value = { armed: true };
            } else if (request.params.expression.includes("state.observer.disconnect")) {
              value = { cleaned: mode !== "page_state" };
            }
          }
          queueMicrotask(() => this.emit("message", {
            data: JSON.stringify({ id: request.id, result: { result: { value } } }),
          }));
        }

        close() {
          this.closeCount += 1;
          this.readyState = CleanupWebSocket.CLOSING;
          if (mode.includes("socket")) return;
          this.readyState = CleanupWebSocket.CLOSED;
          queueMicrotask(() => this.emit("close", {}));
        }
      }

      const session = await connectCdp(
        "ws://127.0.0.1:9222/devtools/page/opaque",
        { WebSocketImpl: CleanupWebSocket, timeoutMs: 50 },
      );
      if (mode === "unarmed") {
        await session.close();
        assert.equal(CleanupWebSocket.instance.closeCount, 1);
        assert.deepEqual(CleanupWebSocket.instance.sentMethods, ["Runtime.enable"]);
        return;
      }
      if (mode === "arm_response_lost") {
        await assert.rejects(session.arm(), { message: "cdp_command_timeout" });
        await session.close();
        assert.equal(CleanupWebSocket.instance.closeCount, 1);
        assert.deepEqual(CleanupWebSocket.instance.sentMethods, [
          "Runtime.enable",
          "Runtime.evaluate",
          "Runtime.evaluate",
        ]);
        return;
      }
      await session.arm();
      await assert.rejects(
        session.close(),
        {
          message: {
            page_command: "observer_page_cleanup_command_failed",
            page_state: "observer_page_cleanup_state_invalid",
            socket: "observer_socket_cleanup_incomplete",
            page_command_socket: "observer_socket_cleanup_incomplete",
          }[mode],
        },
      );
      assert.equal(CleanupWebSocket.instance.closeCount, 1);
    });
  }
});

test("CDP bootstrap error and timeout each close the owned socket once", async (t) => {
  for (const mode of ["error", "timeout"]) {
    await t.test(mode, async () => {
      class FailingBootstrapWebSocket {
        static OPEN = 1;
        static CLOSING = 2;
        static CLOSED = 3;

        constructor() {
          this.readyState = FailingBootstrapWebSocket.OPEN;
          this.listeners = new Map();
          this.sent = [];
          this.closeCount = 0;
          FailingBootstrapWebSocket.instance = this;
          queueMicrotask(() => this.emit("open", {}));
        }

        addEventListener(name, callback, options = {}) {
          const listeners = this.listeners.get(name) ?? [];
          listeners.push({ callback, once: options.once === true });
          this.listeners.set(name, listeners);
        }

        emit(name, event) {
          const listeners = [...(this.listeners.get(name) ?? [])];
          this.listeners.set(name, listeners.filter((listener) => !listener.once));
          for (const listener of listeners) listener.callback(event);
        }

        send(serialized) {
          const request = JSON.parse(serialized);
          this.sent.push(request);
          if (mode === "error") {
            queueMicrotask(() => this.emit("message", {
              data: JSON.stringify({
                id: request.id,
                error: { message: "private bootstrap error", data: "ws://private.invalid" },
              }),
            }));
          }
        }

        close() {
          this.closeCount += 1;
          this.readyState = FailingBootstrapWebSocket.CLOSED;
          queueMicrotask(() => this.emit("close", {}));
        }
      }

      await assert.rejects(
        connectCdp(
          "ws://127.0.0.1:9222/devtools/page/opaque",
          { WebSocketImpl: FailingBootstrapWebSocket, timeoutMs: 20 },
        ),
        (error) => error.message === (
          mode === "error" ? "cdp_command_failed" : "cdp_command_timeout"
        ),
      );
      assert.equal(FailingBootstrapWebSocket.instance.closeCount, 1);
      const serialized = JSON.stringify(FailingBootstrapWebSocket.instance.sent);
      assert.equal(serialized.includes("Browser.close"), false);
      assert.equal(serialized.includes("Page.close"), false);
      assert.equal(serialized.includes("private bootstrap error"), false);
      assert.equal(serialized.includes("private.invalid"), false);
    });
  }
});
