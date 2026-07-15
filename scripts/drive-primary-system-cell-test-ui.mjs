#!/usr/bin/env node

import process from "node:process";
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";

import {
  connectCdp,
  selectProjectionVisualTarget,
} from "./observe-primary-system-cell-visible-response.mjs";

const MIN_TIMEOUT_MS = 500;
const MAX_TIMEOUT_MS = 10_000;
const MAX_TARGET_LIST_BYTES = 256 * 1024;
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

function createResult(resultClass, dispatchCount, startedAt, now, cleanupClass) {
  const result = {
    schema_version: "primary_system_cell_test_ui_driver.v0",
    result_class: resultClass,
    ui_dispatch_count: dispatchCount,
    elapsed_ms: Math.max(0, Math.round(now() - startedAt)),
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

export async function drivePrimarySystemCellTestUi({
  cdpEndpoint,
  timeoutMs = 5_000,
  fetchImpl = globalThis.fetch,
  connectImpl = connectCdp,
  now = () => performance.now(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
} = {}) {
  const startedAt = now();
  let session = null;
  let resultClass = "test_ui_driver_failed";
  let dispatchCount = 0;
  let cleanupClass = "not_started";
  try {
    const endpoint = parseLoopbackCdpEndpoint(cdpEndpoint);
    if (
      !Number.isInteger(timeoutMs) ||
      timeoutMs < MIN_TIMEOUT_MS ||
      timeoutMs > MAX_TIMEOUT_MS ||
      typeof fetchImpl !== "function" ||
      typeof connectImpl !== "function"
    ) {
      throw new TestUiDriverError("test_ui_configuration_invalid");
    }
    const targets = await fetchTargets(endpoint, fetchImpl, timeoutMs);
    const target = selectProjectionVisualTarget(targets);
    session = await connectImpl(target.webSocketDebuggerUrl, { timeoutMs });
    if (
      typeof session?.arm !== "function" ||
      typeof session?.prepareFixedVoiceTestInput !== "function" ||
      typeof session?.dispatchFixedVoiceTestInput !== "function" ||
      typeof session?.close !== "function"
    ) {
      throw new TestUiDriverError("test_ui_cdp_session_invalid");
    }
    await session.arm();
    const inputResult = await session.prepareFixedVoiceTestInput();
    if (inputResult?.inputReady !== true) {
      throw new TestUiDriverError("test_ui_input_unavailable");
    }
    await sleep(50);
    const dispatchResult = await session.dispatchFixedVoiceTestInput();
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
        await session.close();
        cleanupClass = "cdp_session_released";
      } catch {
        cleanupClass = "test_ui_cleanup_incomplete";
        resultClass = "test_ui_cleanup_incomplete";
      }
    } else {
      cleanupClass = "no_cdp_session_created";
    }
  }
  return createResult(resultClass, dispatchCount, startedAt, now, cleanupClass);
}

export function parseArgs(argv) {
  const args = { cdpEndpoint: null, timeoutMs: 5_000 };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const readValue = () => {
      index += 1;
      if (index >= argv.length) throw new TestUiDriverError("test_ui_configuration_invalid");
      return argv[index];
    };
    if (argument === "--cdp-endpoint") args.cdpEndpoint = readValue();
    else if (argument === "--timeout-ms") args.timeoutMs = Number(readValue());
    else throw new TestUiDriverError("test_ui_configuration_invalid");
  }
  return args;
}

async function main() {
  let result;
  try {
    result = await drivePrimarySystemCellTestUi(parseArgs(process.argv.slice(2)));
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
  process.exitCode = result.result_class === "test_ui_seed_dispatched" ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
