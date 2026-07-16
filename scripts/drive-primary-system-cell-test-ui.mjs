#!/usr/bin/env node

import process from "node:process";
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";

import {
  connectCdp,
  selectProjectionVisualTarget,
} from "./observe-primary-system-cell-visible-response.mjs";

const MIN_TIMEOUT_MS = 500;
const MAX_TEST_UI_TIMEOUT_MS = 10_000;
const MAX_OWNER_PREPARATION_TIMEOUT_MS = 20_000;
// connectCdp.close() owns one bounded Runtime.evaluate cleanup (<=1s) followed
// by one bounded WebSocket close handshake (<=1s). Keep a small scheduling
// margin while retaining a fixed cleanup-only ceiling.
const CLEANUP_TIMEOUT_MS = 2_500;
const MAX_TARGET_LIST_BYTES = 256 * 1024;
const FIXED_PROJECTION_VISUAL_URL = "http://127.0.0.1:3000/projection-visual/";
const RESULT_KEYS = Object.freeze([
  "schema_version",
  "result_class",
  "ui_dispatch_count",
  "elapsed_ms",
  "cleanup_class",
  "raw_private_publication_flags",
]);

class TestUiDriverError extends Error {
  constructor(resultClass) {
    super(resultClass);
    this.resultClass = resultClass;
  }
}

function isLoopbackHostname(hostname) {
  const normalized = hostname.toLowerCase().replace(/^\[|\]$/gu, "");
  return normalized === "127.0.0.1" || normalized === "localhost" || normalized === "::1";
}

function parseLoopbackCdpEndpoint(value) {
  let endpoint;
  try {
    endpoint = new URL(value);
  } catch {
    throw new TestUiDriverError("test_ui_configuration_invalid");
  }
  if (
    endpoint.protocol !== "http:" ||
    !isLoopbackHostname(endpoint.hostname) ||
    endpoint.username ||
    endpoint.password ||
    endpoint.search ||
    endpoint.hash ||
    (endpoint.pathname !== "/" && endpoint.pathname !== "")
  ) {
    throw new TestUiDriverError("test_ui_configuration_invalid");
  }
  return endpoint;
}

function createResult(resultClass, dispatchCount, startedAt, finishedAt, cleanupClass) {
  const result = {
    schema_version: "primary_system_cell_test_ui_driver.v0",
    result_class: resultClass,
    ui_dispatch_count: dispatchCount,
    elapsed_ms: Math.max(0, Math.round(finishedAt - startedAt)),
    cleanup_class: cleanupClass,
    raw_private_publication_flags: false,
  };
  return Object.fromEntries(RESULT_KEYS.map((key) => [key, result[key]]));
}

async function fetchTargets(endpoint, fetchImpl, timeoutMs) {
  const targetListUrl = new URL("/json", endpoint);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(targetListUrl, {
      method: "GET",
      redirect: "error",
      signal: controller.signal,
    });
    if (!response?.ok) throw new TestUiDriverError("cdp_endpoint_unavailable");
    const text = await response.text();
    if (Buffer.byteLength(text, "utf8") > MAX_TARGET_LIST_BYTES) {
      throw new TestUiDriverError("cdp_target_list_invalid");
    }
    let targets;
    try {
      targets = JSON.parse(text);
    } catch {
      throw new TestUiDriverError("cdp_target_list_invalid");
    }
    return targets;
  } catch (error) {
    if (error instanceof TestUiDriverError) throw error;
    throw new TestUiDriverError("cdp_endpoint_unavailable");
  } finally {
    clearTimeout(timer);
  }
}

async function createFixedProjectionOwnerTarget(endpoint, fetchImpl, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    // Chrome's fixed endpoint treats the complete query as the target URL.
    // Keep the URL module-owned so callers cannot create arbitrary pages.
    const targetCreateUrl = `${endpoint.origin}/json/new?${FIXED_PROJECTION_VISUAL_URL}`;
    const response = await fetchImpl(targetCreateUrl, {
      method: "PUT",
      redirect: "error",
      signal: controller.signal,
    });
    if (!response?.ok) throw new TestUiDriverError("projection_owner_target_create_failed");
    const text = await response.text();
    if (Buffer.byteLength(text, "utf8") > MAX_TARGET_LIST_BYTES) {
      throw new TestUiDriverError("projection_owner_target_create_failed");
    }
    let created;
    try {
      created = JSON.parse(text);
    } catch {
      throw new TestUiDriverError("projection_owner_target_create_failed");
    }
    if (!created || created.type !== "page") {
      throw new TestUiDriverError("projection_owner_target_create_failed");
    }
  } catch (error) {
    if (error instanceof TestUiDriverError) throw error;
    throw new TestUiDriverError("projection_owner_target_create_failed");
  } finally {
    clearTimeout(timer);
  }
}

function projectionOwnerState(targets) {
  try {
    selectFixedProjectionVisualTarget(targets);
    return "ready";
  } catch (error) {
    if (error?.message === "projection_owner_page_missing") return "missing";
    throw error;
  }
}

function selectFixedProjectionVisualTarget(targets) {
  const target = selectProjectionVisualTarget(targets);
  let targetUrl;
  try {
    targetUrl = new URL(target.url);
  } catch {
    throw new TestUiDriverError("projection_owner_target_invalid");
  }
  const fixedUrl = new URL(FIXED_PROJECTION_VISUAL_URL);
  const normalizedPath = targetUrl.pathname.replace(/\/+$/u, "") || "/";
  const fixedPath = fixedUrl.pathname.replace(/\/+$/u, "") || "/";
  if (
    targetUrl.origin !== fixedUrl.origin ||
    normalizedPath !== fixedPath ||
    targetUrl.search ||
    targetUrl.hash
  ) {
    throw new TestUiDriverError("projection_owner_target_invalid");
  }
  return target;
}

function remainingPreparationBudget(deadline, now) {
  const remaining = Math.floor(deadline - now());
  if (!Number.isFinite(remaining) || remaining <= 0) {
    throw new TestUiDriverError("projection_owner_prepare_timeout");
  }
  return remaining;
}

async function awaitWithinPreparationDeadline(operation, deadline, now) {
  const remaining = remainingPreparationBudget(deadline, now);
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(operation),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new TestUiDriverError("projection_owner_prepare_timeout")),
          Math.max(1, Math.ceil(remaining)),
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function remainingTestUiBudget(deadline, now) {
  const remaining = Math.floor(deadline - now());
  if (!Number.isFinite(remaining) || remaining <= 0) {
    throw new TestUiDriverError("test_ui_input_unavailable");
  }
  return remaining;
}

async function awaitWithinTestUiDeadline(operation, deadline, now) {
  const remaining = remainingTestUiBudget(deadline, now);
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(operation),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new TestUiDriverError("test_ui_input_unavailable")),
          Math.max(1, Math.ceil(remaining)),
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function closeCdpSessionWithinCleanupBound(session) {
  let timer;
  try {
    await Promise.race([
      Promise.resolve().then(() => session.close()),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new TestUiDriverError("test_ui_cleanup_incomplete")),
          CLEANUP_TIMEOUT_MS,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function normalizeCdpCleanupFailure(error) {
  const classes = new Map([
    ["observer_page_cleanup_command_failed", "test_ui_page_cleanup_command_failed"],
    ["observer_page_cleanup_state_invalid", "test_ui_page_cleanup_state_invalid"],
    ["observer_socket_cleanup_incomplete", "test_ui_socket_cleanup_incomplete"],
  ]);
  return classes.get(error?.message) ?? "test_ui_cleanup_incomplete";
}

export async function ensurePrimarySystemCellProjectionOwner({
  cdpEndpoint,
  timeoutMs = 5_000,
  fetchImpl = globalThis.fetch,
  connectImpl = connectCdp,
  now = () => performance.now(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
} = {}) {
  const startedAt = now();
  let deadline = null;
  let session = null;
  let resultClass = "projection_owner_prepare_failed";
  let cleanupClass = "no_cdp_session_created";
  try {
    const endpoint = parseLoopbackCdpEndpoint(cdpEndpoint);
    if (
      !Number.isInteger(timeoutMs) ||
      timeoutMs < MIN_TIMEOUT_MS ||
      timeoutMs > MAX_OWNER_PREPARATION_TIMEOUT_MS ||
      typeof fetchImpl !== "function" ||
      typeof connectImpl !== "function"
    ) {
      throw new TestUiDriverError("test_ui_configuration_invalid");
    }
    deadline = startedAt + timeoutMs;
    let ownerResultClass = "projection_owner_ready";
    let targets = await fetchTargets(
      endpoint,
      fetchImpl,
      remainingPreparationBudget(deadline, now),
    );
    if (projectionOwnerState(targets) !== "ready") {
      await createFixedProjectionOwnerTarget(
        endpoint,
        fetchImpl,
        remainingPreparationBudget(deadline, now),
      );
      while (true) {
        targets = await fetchTargets(
          endpoint,
          fetchImpl,
          remainingPreparationBudget(deadline, now),
        );
        if (projectionOwnerState(targets) === "ready") {
          ownerResultClass = "projection_owner_created";
          break;
        }
        const remaining = remainingPreparationBudget(deadline, now);
        await sleep(Math.min(50, remaining));
      }
    }
    const target = selectFixedProjectionVisualTarget(targets);
    session = await connectImpl(target.webSocketDebuggerUrl, {
      timeoutMs: remainingPreparationBudget(deadline, now),
    });
    if (
      typeof session?.arm !== "function" ||
      typeof session?.prepareFixedVoiceTestInput !== "function" ||
      typeof session?.close !== "function"
    ) {
      throw new TestUiDriverError("test_ui_cdp_session_invalid");
    }
    while (true) {
      const inputResult = await awaitWithinPreparationDeadline(
        () => session.prepareFixedVoiceTestInput(),
        deadline,
        now,
      );
      if (inputResult?.inputReady === true) {
        break;
      }
      const remaining = remainingPreparationBudget(deadline, now);
      await sleep(Math.min(50, remaining));
    }
    await awaitWithinPreparationDeadline(() => session.arm(), deadline, now);
    resultClass = ownerResultClass;
  } catch (error) {
    const safeClasses = new Set([
      "test_ui_configuration_invalid",
      "test_ui_cdp_session_invalid",
      "cdp_endpoint_unavailable",
      "cdp_target_list_invalid",
      "projection_owner_page_missing",
      "projection_owner_page_multiple",
      "projection_owner_target_invalid",
      "projection_owner_target_create_failed",
      "projection_owner_prepare_timeout",
    ]);
    resultClass = safeClasses.has(error?.message) ? error.message : "projection_owner_prepare_failed";
  } finally {
    if (session) {
      try {
        await closeCdpSessionWithinCleanupBound(session);
        cleanupClass = "cdp_session_released";
      } catch (error) {
        cleanupClass = normalizeCdpCleanupFailure(error);
        resultClass = cleanupClass;
      }
    }
  }
  const finishedAt = now();
  if (
    deadline !== null &&
    finishedAt > deadline &&
    (resultClass === "projection_owner_ready" || resultClass === "projection_owner_created")
  ) {
    resultClass = "projection_owner_prepare_timeout";
  }
  return createResult(
    resultClass,
    0,
    startedAt,
    finishedAt,
    cleanupClass,
  );
}

export async function drivePrimarySystemCellTestUi({
  cdpEndpoint,
  timeoutMs = 5_000,
  fetchImpl = globalThis.fetch,
  connectImpl = connectCdp,
  now = () => performance.now(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
} = {}) {
  const startedAt = now();
  let deadline = null;
  let session = null;
  let resultClass = "test_ui_driver_failed";
  let dispatchCount = 0;
  let cleanupClass = "not_started";
  try {
    const endpoint = parseLoopbackCdpEndpoint(cdpEndpoint);
    if (
      !Number.isInteger(timeoutMs) ||
      timeoutMs < MIN_TIMEOUT_MS ||
      timeoutMs > MAX_TEST_UI_TIMEOUT_MS ||
      typeof fetchImpl !== "function" ||
      typeof connectImpl !== "function"
    ) {
      throw new TestUiDriverError("test_ui_configuration_invalid");
    }
    deadline = startedAt + timeoutMs;
    const targets = await fetchTargets(
      endpoint,
      fetchImpl,
      remainingTestUiBudget(deadline, now),
    );
    const target = selectFixedProjectionVisualTarget(targets);
    session = await connectImpl(target.webSocketDebuggerUrl, {
      timeoutMs: remainingTestUiBudget(deadline, now),
    });
    if (
      typeof session?.arm !== "function" ||
      typeof session?.prepareFixedVoiceTestInput !== "function" ||
      typeof session?.dispatchFixedVoiceTestInput !== "function" ||
      typeof session?.close !== "function"
    ) {
      throw new TestUiDriverError("test_ui_cdp_session_invalid");
    }
    await awaitWithinTestUiDeadline(() => session.arm(), deadline, now);
    while (true) {
      const inputResult = await awaitWithinTestUiDeadline(
        () => session.prepareFixedVoiceTestInput(),
        deadline,
        now,
      );
      if (inputResult?.inputReady === true) break;
      const remaining = remainingTestUiBudget(deadline, now);
      await sleep(Math.min(50, remaining));
    }
    await sleep(Math.min(50, remainingTestUiBudget(deadline, now)));
    const dispatchResult = await awaitWithinTestUiDeadline(
      () => session.dispatchFixedVoiceTestInput(),
      deadline,
      now,
    );
    if (dispatchResult?.dispatched !== true) {
      throw new TestUiDriverError("test_ui_dispatch_rejected");
    }
    dispatchCount = 1;
    resultClass = "test_ui_seed_dispatched";
  } catch (error) {
    const safeClasses = new Set([
      "test_ui_configuration_invalid",
      "test_ui_cdp_session_invalid",
      "test_ui_input_unavailable",
      "test_ui_dispatch_rejected",
      "cdp_endpoint_unavailable",
      "cdp_target_list_invalid",
      "projection_owner_page_missing",
      "projection_owner_page_multiple",
      "projection_owner_target_invalid",
    ]);
    resultClass = safeClasses.has(error?.message) ? error.message : "test_ui_driver_failed";
  } finally {
    if (session) {
      try {
        await closeCdpSessionWithinCleanupBound(session);
        cleanupClass = "cdp_session_released";
      } catch (error) {
        cleanupClass = normalizeCdpCleanupFailure(error);
        resultClass = cleanupClass;
      }
    } else {
      cleanupClass = "no_cdp_session_created";
    }
  }
  const finishedAt = now();
  if (
    deadline !== null &&
    finishedAt > deadline &&
    resultClass === "test_ui_seed_dispatched"
  ) {
    resultClass = "test_ui_input_unavailable";
  }
  return createResult(resultClass, dispatchCount, startedAt, finishedAt, cleanupClass);
}

export function parseArgs(argv) {
  const args = { cdpEndpoint: null, timeoutMs: 5_000, prepareOwner: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const readValue = () => {
      index += 1;
      if (index >= argv.length) throw new TestUiDriverError("test_ui_configuration_invalid");
      return argv[index];
    };
    if (argument === "--cdp-endpoint") args.cdpEndpoint = readValue();
    else if (argument === "--timeout-ms") args.timeoutMs = Number(readValue());
    else if (argument === "--prepare-owner") args.prepareOwner = true;
    else throw new TestUiDriverError("test_ui_configuration_invalid");
  }
  return args;
}

async function main() {
  let result;
  try {
    const args = parseArgs(process.argv.slice(2));
    result = args.prepareOwner
      ? await ensurePrimarySystemCellProjectionOwner(args)
      : await drivePrimarySystemCellTestUi(args);
  } catch {
    result = createResult(
      "test_ui_configuration_invalid",
      0,
      performance.now(),
      () => performance.now(),
      "no_cdp_session_created",
    );
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exitCode = new Set([
    "test_ui_seed_dispatched",
    "projection_owner_ready",
    "projection_owner_created",
  ]).has(result.result_class) ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
