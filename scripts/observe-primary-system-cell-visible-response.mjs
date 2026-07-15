#!/usr/bin/env node

import process from "node:process";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import { createInterface } from "node:readline/promises";
import { pathToFileURL } from "node:url";

const RESULT_KEYS = Object.freeze([
  "schema_version",
  "result_class",
  "visible_match_count",
  "observed_at_wall",
  "observer_elapsed_ms",
  "cleanup_class",
  "raw_private_publication_flags",
]);

const DEFAULT_TIMEOUT_MS = 10_000;
const POLL_INTERVAL_MS = 50;
const MIN_TIMEOUT_MS = 100;
const MAX_TIMEOUT_MS = 30_000;
const MESSAGE_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/u;
const FIXED_VOICE_TEST_PROMPT =
  "音声重なりテスト用です。家電は操作せず、十五秒ほど、落ち着いた案内文だけを読み上げてください。";

class ObserverError extends Error {
  constructor(resultClass) {
    super(resultClass);
    this.resultClass = resultClass;
  }
}

function isLoopbackHostname(hostname) {
  const normalized = hostname.toLowerCase().replace(/^\[|\]$/gu, "");
  return normalized === "127.0.0.1" || normalized === "localhost" || normalized === "::1";
}

function parseLoopbackUrl(value, protocols, resultClass) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new ObserverError(resultClass);
  }
  if (!protocols.includes(parsed.protocol) || !isLoopbackHostname(parsed.hostname)) {
    throw new ObserverError(resultClass);
  }
  if (parsed.username || parsed.password) {
    throw new ObserverError(resultClass);
  }
  return parsed;
}

function normalizedPathname(value) {
  const pathname = value === "/" ? value : value.replace(/\/+$/u, "");
  return pathname || "/";
}

export function selectProjectionVisualTarget(targets) {
  if (!Array.isArray(targets)) {
    throw new ObserverError("cdp_target_list_invalid");
  }
  const matches = targets.filter((target) => {
    if (target?.type !== "page" || typeof target.url !== "string") return false;
    try {
      const url = parseLoopbackUrl(target.url, ["http:", "https:"], "cdp_target_list_invalid");
      return normalizedPathname(url.pathname) === "/projection-visual";
    } catch {
      return false;
    }
  });
  if (matches.length === 0) throw new ObserverError("projection_owner_page_missing");
  if (matches.length !== 1) throw new ObserverError("projection_owner_page_multiple");
  if (typeof matches[0].webSocketDebuggerUrl !== "string") {
    throw new ObserverError("projection_owner_target_invalid");
  }
  parseLoopbackUrl(
    matches[0].webSocketDebuggerUrl,
    ["ws:", "wss:"],
    "projection_owner_target_invalid",
  );
  return matches[0];
}

function createOutput(resultClass, visibleMatchCount, startedAtMs, now, overrides = {}) {
  const output = {
    schema_version: "primary_system_cell_visible_response_observation.v1",
    result_class: resultClass,
    visible_match_count: visibleMatchCount,
    observed_at_wall: null,
    observer_elapsed_ms: Math.max(0, Math.round(now() - startedAtMs)),
    cleanup_class: "not_started",
    raw_private_publication_flags: false,
    ...overrides,
  };
  return Object.fromEntries(RESULT_KEYS.map((key) => [key, output[key]]));
}

function armExpression(stateKey) {
  const encodedKey = JSON.stringify(stateKey);
  return `(() => {
    const key = ${encodedKey};
    if (Object.prototype.hasOwnProperty.call(globalThis, key)) return { armed: false };
    const safeId = /^[A-Za-z0-9._:-]{1,128}$/u;
    const state = {
      initialCounts: new Map(),
      firstObservedAtWallMs: new Map(),
      maximumVisibleCounts: new Map(),
      initialized: false,
      observer: null,
      scan: null,
    };
    const visible = (element) => {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== "none" && style.visibility !== "hidden" &&
          Number(style.opacity || "1") > 0 && rect.width > 0 && rect.height > 0;
    };
    state.scan = () => {
      const counts = new Map();
      for (const element of document.querySelectorAll(".td-assistant-bubble")) {
        const id = element.dataset.speechBubbleMessageId;
        if (safeId.test(id || "") && visible(element)) {
          counts.set(id, (counts.get(id) || 0) + 1);
        }
      }
      for (const [id, count] of counts.entries()) {
        const maximum = Math.max(state.maximumVisibleCounts.get(id) || 0, count);
        state.maximumVisibleCounts.set(id, maximum);
        if (!state.initialized) state.initialCounts.set(id, count);
        else if (!state.firstObservedAtWallMs.has(id)) {
          state.firstObservedAtWallMs.set(id, Date.now());
        }
      }
    };
    state.scan();
    state.initialized = true;
    state.observer = new MutationObserver(() => requestAnimationFrame(state.scan));
    state.observer.observe(document.documentElement, {
      attributes: true,
      childList: true,
      subtree: true,
      attributeFilter: ["class", "style", "data-speech-bubble-message-id"],
    });
    globalThis[key] = state;
    return { armed: true };
  })()`;
}

function inspectionExpression(stateKey, messageId) {
  const encodedKey = JSON.stringify(stateKey);
  const encodedId = JSON.stringify(messageId);
  return `(() => {
    const state = globalThis[${encodedKey}];
    if (!state || typeof state.scan !== "function") return null;
    state.scan();
    const id = ${encodedId};
    return {
      initialMatchCount: state.initialCounts.get(id) || 0,
      maximumVisibleMatchCount: state.maximumVisibleCounts.get(id) || 0,
      firstObservedAtWallMs: state.firstObservedAtWallMs.get(id) || null,
    };
  })()`;
}

function cleanupExpression(stateKey) {
  const encodedKey = JSON.stringify(stateKey);
  return `(() => {
    const state = globalThis[${encodedKey}];
    if (!state || !state.observer) return { cleaned: false };
    state.observer.disconnect();
    state.initialCounts.clear();
    state.firstObservedAtWallMs.clear();
    state.maximumVisibleCounts.clear();
    delete globalThis[${encodedKey}];
    return { cleaned: true };
  })()`;
}

function fixedVoiceTestInputExpression() {
  const prompt = JSON.stringify(FIXED_VOICE_TEST_PROMPT);
  return `(() => {
    const textarea = document.querySelector('textarea');
    if (!(textarea instanceof HTMLTextAreaElement) || textarea.disabled) {
      return { inputReady: false };
    }
    const setter = Object.getOwnPropertyDescriptor(
      HTMLTextAreaElement.prototype,
      'value'
    )?.set;
    if (typeof setter !== 'function') return { inputReady: false };
    setter.call(textarea, ${prompt});
    textarea.dispatchEvent(new InputEvent('input', {
      bubbles: true,
      inputType: 'insertText',
      data: null,
    }));
    return { inputReady: textarea.value.length > 0 };
  })()`;
}

function fixedVoiceTestDispatchExpression() {
  return `(() => {
    const textarea = document.querySelector('textarea');
    if (!(textarea instanceof HTMLTextAreaElement) || textarea.disabled) {
      return { dispatched: false };
    }
    const event = new KeyboardEvent('keydown', {
      key: 'Enter',
      code: 'Enter',
      bubbles: true,
      cancelable: true,
      shiftKey: false,
    });
    textarea.dispatchEvent(event);
    return { dispatched: event.defaultPrevented === true };
  })()`;
}

function normalizeInspection(value) {
  const initialCount = Number(value?.initialMatchCount);
  const maximumCount = Number(value?.maximumVisibleMatchCount);
  const observedAtWallMs = value?.firstObservedAtWallMs;
  if (
    !Number.isSafeInteger(initialCount) || initialCount < 0 || initialCount > 100 ||
    !Number.isSafeInteger(maximumCount) || maximumCount < 0 || maximumCount > 100 ||
    (observedAtWallMs !== null &&
      (!Number.isSafeInteger(observedAtWallMs) || observedAtWallMs < 0))
  ) {
    throw new ObserverError("cdp_observation_invalid");
  }
  return { initialCount, maximumCount, observedAtWallMs };
}

async function fetchTargets(cdpEndpoint, fetchImpl, timeoutMs) {
  const endpoint = new URL("/json/list", cdpEndpoint);
  let response;
  try {
    response = await fetchImpl(endpoint, { signal: AbortSignal.timeout(Math.min(timeoutMs, 5_000)) });
  } catch {
    throw new ObserverError("cdp_endpoint_unavailable");
  }
  if (!response?.ok) throw new ObserverError("cdp_endpoint_unavailable");
  try {
    return await response.json();
  } catch {
    throw new ObserverError("cdp_target_list_invalid");
  }
}

async function closeOwnedSocket(ws, WebSocketImpl, timeoutMs = 1_000) {
  if (ws.readyState === WebSocketImpl.CLOSED) return;
  await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new ObserverError("observer_cleanup_incomplete")),
      timeoutMs,
    );
    ws.addEventListener("close", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
    try {
      if (ws.readyState !== WebSocketImpl.CLOSING) ws.close();
    } catch {
      clearTimeout(timer);
      reject(new ObserverError("observer_cleanup_incomplete"));
    }
  });
}

async function awaitWithinDeadline(operation, remainingMs, timeoutClass) {
  if (!Number.isFinite(remainingMs) || remainingMs <= 0) {
    throw new ObserverError(timeoutClass);
  }
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(operation),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new ObserverError(timeoutClass)),
          Math.max(1, Math.ceil(remainingMs)),
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

export async function connectCdp(
  webSocketUrl,
  { WebSocketImpl = globalThis.WebSocket, timeoutMs = 5_000 } = {},
) {
  if (typeof WebSocketImpl !== "function") throw new ObserverError("cdp_client_unavailable");
  const ws = new WebSocketImpl(webSocketUrl);
  const stateKey = `__sword_psc_visible_observer_${randomUUID().replaceAll("-", "")}`;
  const pending = new Map();
  let nextId = 1;
  let closeCount = 0;

  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new ObserverError("cdp_target_unavailable")),
        Math.min(timeoutMs, 5_000),
      );
      ws.addEventListener("open", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      ws.addEventListener("error", () => {
        clearTimeout(timer);
        reject(new ObserverError("cdp_target_unavailable"));
      }, { once: true });
    });
  } catch (error) {
    try {
      await closeOwnedSocket(ws, WebSocketImpl, Math.min(timeoutMs, 1_000));
    } catch {
      throw new ObserverError("observer_cleanup_incomplete");
    }
    throw error;
  }

  ws.addEventListener("message", (event) => {
    let message;
    try {
      message = JSON.parse(String(event.data));
    } catch {
      return;
    }
    if (!Number.isInteger(message?.id) || !pending.has(message.id)) return;
    const { resolve, reject, timer } = pending.get(message.id);
    pending.delete(message.id);
    clearTimeout(timer);
    if (message.error) reject(new ObserverError("cdp_command_failed"));
    else resolve(message.result);
  });

  ws.addEventListener("close", () => {
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(new ObserverError("cdp_target_detached"));
    }
    pending.clear();
  });

  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId;
    nextId += 1;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new ObserverError("cdp_command_timeout"));
    }, Math.min(timeoutMs, 1_000));
    pending.set(id, { resolve, reject, timer });
    try {
      ws.send(JSON.stringify({ id, method, params }));
    } catch {
      pending.delete(id);
      clearTimeout(timer);
      reject(new ObserverError("cdp_command_failed"));
    }
  });

  try {
    await send("Runtime.enable");
  } catch (error) {
    try {
      await closeOwnedSocket(ws, WebSocketImpl, Math.min(timeoutMs, 1_000));
    } catch {
      throw new ObserverError("observer_cleanup_incomplete");
    }
    throw error;
  }

  return {
    async prepareFixedVoiceTestInput() {
      const result = await send("Runtime.evaluate", {
        expression: fixedVoiceTestInputExpression(),
        returnByValue: true,
        awaitPromise: false,
      });
      return result?.result?.value;
    },
    async dispatchFixedVoiceTestInput() {
      const result = await send("Runtime.evaluate", {
        expression: fixedVoiceTestDispatchExpression(),
        returnByValue: true,
        awaitPromise: false,
      });
      return result?.result?.value;
    },
    async arm() {
      const result = await send("Runtime.evaluate", {
        expression: armExpression(stateKey),
        returnByValue: true,
        awaitPromise: false,
      });
      if (result?.result?.value?.armed !== true) {
        throw new ObserverError("cdp_observer_arm_failed");
      }
    },
    async inspect(messageId) {
      const result = await send("Runtime.evaluate", {
        expression: inspectionExpression(stateKey, messageId),
        returnByValue: true,
        awaitPromise: false,
      });
      return result?.result?.value;
    },
    async close() {
      closeCount += 1;
      if (closeCount !== 1) throw new ObserverError("observer_cleanup_incomplete");
      if (ws.readyState === WebSocketImpl.CLOSED) {
        throw new ObserverError("observer_cleanup_incomplete");
      }
      let pageCleanupClear = false;
      try {
        const cleanupResult = await send("Runtime.evaluate", {
          expression: cleanupExpression(stateKey),
          returnByValue: true,
          awaitPromise: false,
        });
        pageCleanupClear = cleanupResult?.result?.value?.cleaned === true;
      } finally {
        await closeOwnedSocket(ws, WebSocketImpl);
      }
      if (!pageCleanupClear) throw new ObserverError("observer_cleanup_incomplete");
    },
  };
}

export async function observeVisibleResponse({
  cdpEndpoint,
  messageId,
  messageIdProvider,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  fetchImpl = globalThis.fetch,
  connectImpl = connectCdp,
  now = () => performance.now(),
  wallNowMs = () => Date.now(),
  onArmed = async () => {},
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
} = {}) {
  const startedAtMs = now();
  const startedAtWallMs = wallNowMs();
  let session = null;
  let output;
  try {
    const parsedEndpoint = parseLoopbackUrl(cdpEndpoint, ["http:"], "invalid_request");
    if (
      messageId !== null && messageId !== undefined &&
      !MESSAGE_ID_PATTERN.test(String(messageId))
    ) {
      throw new ObserverError("invalid_request");
    }
    if (messageId === null || messageId === undefined) {
      if (typeof messageIdProvider !== "function") throw new ObserverError("invalid_request");
    }
    if (!Number.isInteger(timeoutMs) || timeoutMs < MIN_TIMEOUT_MS || timeoutMs > MAX_TIMEOUT_MS) {
      throw new ObserverError("invalid_request");
    }
    if (typeof fetchImpl !== "function" || typeof connectImpl !== "function") {
      throw new ObserverError("invalid_request");
    }

    const targets = await fetchTargets(parsedEndpoint, fetchImpl, timeoutMs);
    const target = selectProjectionVisualTarget(targets);
    session = await connectImpl(target.webSocketDebuggerUrl, {
      timeoutMs: Math.max(MIN_TIMEOUT_MS, timeoutMs - (now() - startedAtMs)),
    });
    if (typeof session.arm !== "function") throw new ObserverError("cdp_observer_arm_failed");
    await session.arm();
    await awaitWithinDeadline(
      onArmed,
      timeoutMs - (now() - startedAtMs),
      "visible_response_timeout",
    );
    const expectedMessageId = messageId ?? await awaitWithinDeadline(
      messageIdProvider,
      timeoutMs - (now() - startedAtMs),
      "visible_response_expected_id_timeout",
    );
    if (!MESSAGE_ID_PATTERN.test(String(expectedMessageId ?? ""))) {
      throw new ObserverError("invalid_request");
    }

    while (now() - startedAtMs < timeoutMs) {
      const remainingMs = timeoutMs - (now() - startedAtMs);
      await sleep(Math.min(POLL_INTERVAL_MS, remainingMs));
      const inspection = normalizeInspection(await session.inspect(expectedMessageId));
      if (inspection.initialCount > 0) {
        throw new ObserverError("visible_response_stale_initial_match");
      }
      if (inspection.maximumCount > 1) throw new ObserverError("visible_response_duplicate");
      if (inspection.observedAtWallMs !== null) {
        const currentWallMs = wallNowMs();
        if (
          inspection.observedAtWallMs < startedAtWallMs - 1_000 ||
          inspection.observedAtWallMs > currentWallMs + 1_000
        ) {
          throw new ObserverError("cdp_observation_invalid");
        }
        output = createOutput("visible_response_observed", 1, startedAtMs, now, {
          observed_at_wall: new Date(inspection.observedAtWallMs).toISOString(),
        });
        break;
      }
    }
    if (!output) throw new ObserverError("visible_response_timeout");
  } catch (error) {
    const resultClass = error instanceof ObserverError
      ? error.resultClass
      : session
        ? "cdp_observation_failed"
        : "observer_internal_failure";
    const visibleMatchCount = resultClass === "visible_response_duplicate" ? 2 : 0;
    output = createOutput(resultClass, visibleMatchCount, startedAtMs, now);
  } finally {
    if (session) {
      try {
        await session.close();
        output.cleanup_class = "observer_socket_released";
      } catch {
        output.result_class = "observer_cleanup_incomplete";
        output.cleanup_class = "observer_cleanup_incomplete";
      }
    }
  }
  output.observer_elapsed_ms = Math.max(0, Math.round(now() - startedAtMs));
  return Object.fromEntries(RESULT_KEYS.map((key) => [key, output[key]]));
}

export function parseArgs(argv) {
  const args = {
    cdpEndpoint: null,
    messageId: null,
    messageIdStdin: false,
    timeoutMs: DEFAULT_TIMEOUT_MS,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const readValue = () => {
      index += 1;
      if (index >= argv.length) throw new ObserverError("invalid_request");
      return argv[index];
    };
    if (arg === "--cdp-endpoint") args.cdpEndpoint = readValue();
    else if (arg === "--message-id") args.messageId = readValue();
    else if (arg === "--message-id-stdin") args.messageIdStdin = true;
    else if (arg === "--timeout-ms") args.timeoutMs = Number(readValue());
    else throw new ObserverError("invalid_request");
  }
  return args;
}

async function main() {
  let result;
  let input = null;
  try {
    const args = parseArgs(process.argv.slice(2));
    if (Boolean(args.messageId) === args.messageIdStdin) {
      throw new ObserverError("invalid_request");
    }
    let messageIdProvider;
    let onArmed;
    if (args.messageIdStdin) {
      input = createInterface({ input: process.stdin, crlfDelay: Infinity });
      messageIdProvider = async () => {
        const next = await input[Symbol.asyncIterator]().next();
        return next.done ? null : next.value;
      };
      onArmed = async () => {
        process.stdout.write(`${JSON.stringify({
          schema_version: "primary_system_cell_visible_response_observer_arm.v1",
          result_class: "observer_armed",
          raw_private_publication_flags: false,
        })}\n`);
      };
    }
    result = await observeVisibleResponse({
      cdpEndpoint: args.cdpEndpoint,
      messageId: args.messageId,
      messageIdProvider,
      timeoutMs: args.timeoutMs,
      onArmed,
    });
  } catch {
    result = createOutput("invalid_request", 0, Date.now(), () => Date.now());
  } finally {
    input?.close();
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exitCode = result.result_class === "visible_response_observed" ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
