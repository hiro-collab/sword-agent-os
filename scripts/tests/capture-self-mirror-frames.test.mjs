import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  captureFrames,
  createCdpFrameCapture,
  dispatchDanceStop,
  isProjectionVisualDiagnosticsReadyForTrigger,
  renderSettleMsForTrigger,
  releaseCountEligibleAtMs,
} from "../capture-self-mirror-frames.mjs";

const capturePath = new URL(
  "../capture-self-mirror-frames.mjs",
  import.meta.url,
);
const wrapperPath = new URL("../run-self-mirror-proof.ps1", import.meta.url);
const routesPath = new URL(
  "../../runtime/visual-motion-analyzer/self-mirror-consumer-routes.json",
  import.meta.url,
);

const PNG_DATA =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl5cS8AAAAASUVORK5CYII=";
const PNG_BYTES = Buffer.from(PNG_DATA, "base64");

function createFakeCdpPage(
  responses,
  {
    detachError = null,
    evaluateErrorForKind = null,
    evaluateHandler = null,
  } = {},
) {
  const events = [];
  let detached = 0;
  let pageScreenshotCalls = 0;
  const cdpSession = {
    async send(method, options) {
      events.push({ type: "send", method, options });
      const response = responses.shift();
      return typeof response === "function" ? await response() : response;
    },
    async detach() {
      detached += 1;
      events.push({ type: "detach" });
      if (detachError) throw detachError;
    },
  };
  const page = {
    context() {
      return {
        async newCDPSession(target) {
          assert.equal(target, page);
          events.push({ type: "session" });
          return cdpSession;
        },
      };
    },
    async screenshot() {
      pageScreenshotCalls += 1;
      throw new Error("page screenshot must not be used");
    },
    async evaluate(callback, payload) {
      if (payload?.kind) {
        events.push({ type: "page_evaluate", kind: payload.kind });
        if (payload.kind === evaluateErrorForKind) {
          throw new Error("private_native_path_must_not_echo");
        }
      }
      if (evaluateHandler) {
        return await evaluateHandler(callback, payload, events);
      }
      return 0;
    },
  };
  return {
    page,
    events,
    get detached() {
      return detached;
    },
    get pageScreenshotCalls() {
      return pageScreenshotCalls;
    },
  };
}

function captureArgs() {
  return {
    durationMs: 1,
    sampleRateFps: 2000,
    trigger: "none",
    triggerAtMs: 700,
    danceStopAtMs: 0,
    danceSettleAtMs: 0,
  };
}

test("expression capture waits for an applied frame instead of freezing the queue acknowledgement", () => {
  assert.equal(
    isProjectionVisualDiagnosticsReadyForTrigger(
      "expression-visible",
      {
        expression_weight_applied: false,
        frame_applied_count: 0,
        driver_result_id: "driver-current",
        last_driver_result_id: "driver-current",
        runtime_status: "started",
        runtime_reason_code: "motion_runtime_expression_frame_queued",
      },
      "driver-current",
    ),
    false,
  );
  assert.equal(
    isProjectionVisualDiagnosticsReadyForTrigger(
      "expression-visible",
      {
        expression_weight_applied: true,
        frame_applied_count: 1,
        driver_result_id: "driver-current",
        last_driver_result_id: "driver-current",
      },
      "driver-current",
    ),
    true,
  );
  assert.equal(
    isProjectionVisualDiagnosticsReadyForTrigger("context-nod", {
      expression_weight_applied: false,
      frame_applied_count: 0,
    }),
    true,
  );
  assert.equal(
    isProjectionVisualDiagnosticsReadyForTrigger(
      "expression-visible",
      null,
      "driver-current",
    ),
    false,
  );
  assert.equal(
    isProjectionVisualDiagnosticsReadyForTrigger(
      "expression-visible",
      {
        expression_weight_applied: true,
        frame_applied_count: 1,
        driver_result_id: "driver-stale",
        last_driver_result_id: "driver-stale",
      },
      "driver-current",
    ),
    false,
  );
});

test("only expression capture yields a bounded render-only settle window", () => {
  assert.equal(renderSettleMsForTrigger("expression-visible"), 650);
  assert.equal(renderSettleMsForTrigger("context-nod"), 0);
  assert.equal(renderSettleMsForTrigger("dance"), 0);
  assert.equal(renderSettleMsForTrigger("none"), 0);
});

test("expression capture waits for current correlated diagnostics before the first post-trigger frame", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "self-mirror-cdp-"));
  let diagnosticsReadCount = 0;
  const fake = createFakeCdpPage([{ data: PNG_DATA }, { data: PNG_DATA }], {
    evaluateHandler(callback, payload, events) {
      if (payload?.kind === "expression") return undefined;
      const source = String(callback);
      if (source.includes("__projectionVisualMotionStimulusResult")) {
        return {
          accepted: true,
          status: "started",
          reason_code: "motion_runtime_expression_frame_queued",
          safe_visible_state: "expression_change_requested",
          stimulus_id: "expression.visible.face.browser",
          driver_result_id: "safe_driver",
        };
      }
      if (source.includes("__projectionVisualInPageDiagnostics")) {
        diagnosticsReadCount += 1;
        const current = diagnosticsReadCount >= 2;
        events.push({
          type: current ? "diagnostics_current" : "diagnostics_stale",
        });
        return {
          expression_weight_applied: true,
          frame_applied_count: 1,
          driver_result_id: current ? "safe_driver" : "stale_driver",
          last_driver_result_id: current ? "safe_driver" : "stale_driver",
        };
      }
      return 0;
    },
  });
  try {
    const result = await captureFrames(fake.page, tempDir, {
      ...captureArgs(),
      trigger: "expression-visible",
      triggerAtMs: 0,
      expressionDiagnosticsTimeoutMs: 100,
      motionEventId: "safe_event",
      stimulusInstanceId: "safe_instance",
      driverResultId: "safe_driver",
      scenarioId: "safe_scenario",
      expressionProfile: "default",
    });
    assert.equal(
      result.startProjectionVisualDiagnostics.frame_applied_count,
      1,
    );
    const firstSendIndex = fake.events.findIndex(
      (event) => event.type === "send",
    );
    const appliedIndex = fake.events.findIndex(
      (event) => event.type === "diagnostics_current",
    );
    assert.ok(appliedIndex >= 0);
    assert.ok(firstSendIndex > appliedIndex);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("expression capture fails closed without a screenshot or unready fallback when no frame applies", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "self-mirror-cdp-"));
  const fake = createFakeCdpPage([], {
    evaluateHandler(callback, payload) {
      if (payload?.kind === "expression") return undefined;
      const source = String(callback);
      if (source.includes("__projectionVisualMotionStimulusResult")) {
        return {
          accepted: true,
          status: "started",
          reason_code: "motion_runtime_expression_frame_queued",
          safe_visible_state: "expression_change_requested",
          stimulus_id: "expression.visible.face.browser",
          driver_result_id: "safe_driver",
        };
      }
      if (source.includes("__projectionVisualInPageDiagnostics")) {
        return {
          expression_weight_applied: true,
          frame_applied_count: 1,
          driver_result_id: "permanent_mismatch",
          last_driver_result_id: "permanent_mismatch",
        };
      }
      return 0;
    },
  });
  try {
    await assert.rejects(
      captureFrames(fake.page, tempDir, {
        ...captureArgs(),
        trigger: "expression-visible",
        triggerAtMs: 0,
        expressionDiagnosticsTimeoutMs: 10,
        motionEventId: "safe_event",
        stimulusInstanceId: "safe_instance",
        driverResultId: "safe_driver",
        scenarioId: "safe_scenario",
        expressionProfile: "default",
      }),
      { message: "self_mirror_expression_frame_not_applied" },
    );
    assert.equal(
      fake.events.filter((event) => event.type === "send").length,
      0,
    );
    assert.deepEqual(await readdir(tempDir), []);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("frame capture uses one page CDP session and writes PNG frames in exact order", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "self-mirror-cdp-"));
  const fake = createFakeCdpPage([{ data: PNG_DATA }, { data: PNG_DATA }]);
  try {
    const result = await captureFrames(fake.page, tempDir, captureArgs());
    assert.deepEqual(
      result.framePaths.map((framePath) => path.basename(framePath)),
      ["frame_0000.png", "frame_0001.png"],
    );
    assert.equal(fake.pageScreenshotCalls, 0);
    assert.equal(fake.detached, 1);
    const sendEvents = fake.events.filter((event) => event.type === "send");
    assert.deepEqual(
      sendEvents.map((event) => event.method),
      ["Page.captureScreenshot", "Page.captureScreenshot"],
    );
    assert.ok(
      sendEvents.every(
        (event) =>
          event.options.format === "png" &&
          event.options.fromSurface === true &&
          event.options.captureBeyondViewport === false,
      ),
    );
    assert.deepEqual(await readFile(result.framePaths[0]), PNG_BYTES);
    assert.deepEqual(await readFile(result.framePaths[1]), PNG_BYTES);
    assert.deepEqual(
      fake.events.map((event) => event.type),
      ["session", "send", "send", "detach"],
    );
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("CDP capture failure preserves same-page fail-safe dance stop cleanup", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "self-mirror-cdp-"));
  const fake = createFakeCdpPage([{ data: "invalid" }]);
  try {
    await assert.rejects(
      captureFrames(fake.page, tempDir, {
        ...captureArgs(),
        trigger: "dance",
        triggerAtMs: 0,
        danceStopAtMs: 1000,
        motionEventId: "safe_event",
        stimulusInstanceId: "safe_instance",
        driverResultId: "safe_driver",
        dancePayloadShape: "fixture",
        scenarioId: "safe_scenario",
      }),
      { message: "self_mirror_cdp_screenshot_invalid" },
    );
    assert.equal(fake.detached, 1);
    assert.deepEqual(
      fake.events.map((event) =>
        event.type === "page_evaluate"
          ? `${event.type}:${event.kind}`
          : event.type,
      ),
      [
        "session",
        "page_evaluate:dance",
        "send",
        "detach",
        "page_evaluate:stop",
      ],
    );
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("dance-stop cleanup failure outranks detach and capture failures without raw echo", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "self-mirror-cdp-"));
  const fake = createFakeCdpPage([{ data: "private_capture_payload" }], {
    detachError: new Error("private_detach_payload"),
    evaluateErrorForKind: "stop",
  });
  try {
    await assert.rejects(
      captureFrames(fake.page, tempDir, {
        ...captureArgs(),
        trigger: "dance",
        triggerAtMs: 0,
        danceStopAtMs: 1000,
        motionEventId: "safe_event",
        stimulusInstanceId: "safe_instance",
        driverResultId: "safe_driver",
        dancePayloadShape: "fixture",
        scenarioId: "safe_scenario",
      }),
      (error) => {
        assert.equal(error.message, "self_mirror_dance_stop_cleanup_failed");
        assert.equal(error.code, "self_mirror_dance_stop_cleanup_failed");
        assert.doesNotMatch(String(error), /private|native|path|payload/i);
        return true;
      },
    );
    assert.equal(fake.detached, 1);
    assert.equal(
      fake.events.filter(
        (event) => event.type === "page_evaluate" && event.kind === "stop",
      ).length,
      1,
    );
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("detach failure outranks a primary capture failure without raw echo", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "self-mirror-cdp-"));
  const fake = createFakeCdpPage([{ data: "private_capture_payload" }], {
    detachError: new Error("private_detach_payload"),
  });
  try {
    await assert.rejects(
      captureFrames(fake.page, tempDir, captureArgs()),
      (error) => {
        assert.equal(error.message, "self_mirror_cdp_detach_failed");
        assert.equal(error.code, "self_mirror_cdp_detach_failed");
        assert.doesNotMatch(String(error), /private|payload/i);
        return true;
      },
    );
    assert.equal(fake.detached, 1);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

for (const [label, detachError, expectedCode] of [
  ["detaches", null, "self_mirror_cdp_session_unavailable"],
  [
    "surfaces fixed detach failure",
    new Error("private_session_detach_payload"),
    "self_mirror_cdp_detach_failed",
  ],
]) {
  test(`created malformed CDP session ${label} exactly once`, async () => {
    let detachCount = 0;
    const page = {
      context() {
        return {
          async newCDPSession() {
            return {
              async detach() {
                detachCount += 1;
                if (detachError) throw detachError;
              },
            };
          },
        };
      },
    };
    await assert.rejects(createCdpFrameCapture(page), (error) => {
      assert.equal(error.message, expectedCode);
      assert.equal(error.code, expectedCode);
      assert.doesNotMatch(String(error), /private|payload/i);
      return true;
    });
    assert.equal(detachCount, 1);
  });
}

test("CDP session with send but no detach fails before capture and write", async () => {
  let sendCount = 0;
  let writeCount = 0;
  const page = {
    context() {
      return {
        async newCDPSession() {
          return {
            async send() {
              sendCount += 1;
              throw new Error("private_native_capture_payload");
            },
          };
        },
      };
    },
  };

  await assert.rejects(
    createCdpFrameCapture(page, async () => {
      writeCount += 1;
      throw new Error("private_path_write_payload");
    }),
    (error) => {
      assert.equal(error.message, "self_mirror_cdp_session_unavailable");
      assert.equal(error.code, "self_mirror_cdp_session_unavailable");
      assert.doesNotMatch(String(error), /private|native|path|payload/i);
      return true;
    },
  );
  assert.equal(sendCount, 0);
  assert.equal(writeCount, 0);
});

for (const [label, bytes] of [
  ["header-only", PNG_BYTES.subarray(0, 33)],
  ["truncated", PNG_BYTES.subarray(0, PNG_BYTES.length - 1)],
  [
    "forged terminal chunk",
    (() => {
      const forged = Buffer.from(PNG_BYTES);
      forged.writeUInt32BE(1, forged.length - 12);
      return forged;
    })(),
  ],
]) {
  test(`frame capture rejects ${label} PNG structure before writing`, async () => {
    const tempDir = await mkdtemp(path.join(os.tmpdir(), "self-mirror-cdp-"));
    const fake = createFakeCdpPage([{ data: bytes.toString("base64") }]);
    try {
      await assert.rejects(captureFrames(fake.page, tempDir, captureArgs()), {
        message: "self_mirror_cdp_screenshot_invalid",
      });
      assert.deepEqual(await readdir(tempDir), []);
      assert.equal(fake.detached, 1);
    } finally {
      await rm(tempDir, { recursive: true, force: true });
    }
  });
}

for (const [label, response] of [
  ["missing", {}],
  ["malformed", { data: "private_marker_not_base64" }],
]) {
  test(`frame capture fails closed for ${label} CDP screenshot data without raw echo`, async () => {
    const tempDir = await mkdtemp(path.join(os.tmpdir(), "self-mirror-cdp-"));
    const fake = createFakeCdpPage([response]);
    try {
      await assert.rejects(
        captureFrames(fake.page, tempDir, captureArgs()),
        (error) => {
          assert.equal(error.message, "self_mirror_cdp_screenshot_invalid");
          assert.equal(error.code, "self_mirror_cdp_screenshot_invalid");
          assert.doesNotMatch(String(error), /private_marker_not_base64/);
          return true;
        },
      );
      assert.equal(fake.pageScreenshotCalls, 0);
      assert.equal(fake.detached, 1);
      assert.deepEqual(
        fake.events.map((event) => event.type),
        ["session", "send", "detach"],
      );
    } finally {
      await rm(tempDir, { recursive: true, force: true });
    }
  });
}

test("dance lifecycle capture schedules one same-page stop with fixed safe fields", async () => {
  const source = await readFile(capturePath, "utf8");
  assert.doesNotMatch(source, /page\.screenshot/);
  assert.match(source, /Page\.captureScreenshot/);
  assert.match(source, /--dance-stop-at-ms/);
  assert.match(source, /--dance-settle-at-ms/);
  assert.match(source, /export async function dispatchDanceStop\(/);
  assert.match(source, /kind: "stop"/);
  assert.match(source, /request_mode: "stop"/);
  assert.match(source, /payload_ref: "motion\.thought_core\.stop\.v0"/);
  assert.match(source, /stop_target: "dance\.sequence"/);
  assert.match(source, /dispatch_class: dispatchClass/);
  assert.match(source, /"fail_safe"/);
});

test("dance lifecycle output is count-only and timing fails closed", async () => {
  const source = await readFile(capturePath, "utf8");
  assert.match(source, /after_release_active_instance_count/);
  assert.match(source, /after_release_sampled_at_ms/);
  assert.match(source, /final_active_instance_count/);
  assert.match(source, /args\.danceStopAtMs <= args\.triggerAtMs/);
  assert.match(source, /args\.danceStopAtMs >= args\.durationMs/);
  assert.match(source, /args\.danceSettleAtMs <= args\.danceStopAtMs/);
  assert.match(source, /releaseCountEligibleAtMs\(args, danceStopResult\)/);
  assert.match(source, /danceInstancesAfterReleaseSampledAtMs = elapsedMs/);
  assert.doesNotMatch(source, /dance_runtime_counts:[\s\S]{0,160}instance_id/);
  assert.match(source, /target_identity: retainedCaptureTargetIdentity\(\)/);
  const retainedIdentity = source.match(
    /function retainedCaptureTargetIdentity\(\) \{([\s\S]*?)\n\}/,
  );
  assert.ok(retainedIdentity);
  assert.doesNotMatch(
    retainedIdentity[1],
    /args\.url|capture_target_url|trigger_target_url/,
  );
  assert.match(retainedIdentity[1], /projection_visual_local_route/);
});

test("delayed stop shifts release-count eligibility and cannot sample early", () => {
  const args = { danceStopAtMs: 3900, danceSettleAtMs: 5900 };
  const eligibleAtMs = releaseCountEligibleAtMs(args, {
    dispatched: true,
    dispatched_at_ms: 4002,
  });
  assert.equal(eligibleAtMs, 6002);
  assert.ok(5900 < eligibleAtMs);
  assert.equal(
    releaseCountEligibleAtMs(args, {
      dispatched: true,
      dispatched_at_ms: Number.NaN,
    }),
    null,
  );
});

test("stop dispatch timestamp is taken after a delayed page dispatch", async () => {
  let currentEpochMs = 1000;
  const page = {
    async evaluate() {
      currentEpochMs = 1120;
    },
  };
  const args = {
    motionEventId: "event",
    stimulusInstanceId: "instance",
    driverResultId: "driver",
    captureStartedAtEpochMs: 500,
    danceStopAtMs: 3900,
    danceSettleAtMs: 5900,
  };
  const result = await dispatchDanceStop(
    page,
    args,
    "scheduled",
    () => currentEpochMs,
  );
  assert.equal(result.dispatched_at_ms, 620);
  assert.equal(releaseCountEligibleAtMs(args, result), 2620);
});

test("wrapper preserves a twelve-second post-stop settle and route is discoverable", async () => {
  const wrapper = await readFile(wrapperPath, "utf8");
  assert.match(wrapper, /\[int\]\$DanceStopAtMs = 0/);
  assert.match(
    wrapper,
    /-DanceStopAtMs is allowed only for Browser dance capture/,
  );
  assert.match(wrapper, /required post-stop observation window/);
  assert.match(wrapper, /\$postReleaseMargin = 500/);
  assert.match(wrapper, /--dance-settle-at-ms/);

  const catalog = JSON.parse(await readFile(routesPath, "utf8"));
  const route = catalog.routes.find(
    (candidate) =>
      candidate.route_id === "self_mirror.browser.dance_start_stop_lifecycle",
  );
  assert.ok(route);
  assert.match(route.command_template, /-DanceStopAtMs 3900/);
  assert.match(route.command_template, /-DurationMs 18000/);
  assert.ok(
    catalog.result_package_files.includes("self_mirror_capture_manifest.json"),
  );
  assert.match(wrapper, /"self_mirror_capture_manifest\.json"/);
});
