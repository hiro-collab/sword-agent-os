#!/usr/bin/env node

import { createRequire } from "node:module";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const scriptPath = new URL(import.meta.url).pathname;
const scriptDir = path.dirname(process.platform === "win32" && scriptPath.startsWith("/") ? scriptPath.slice(1) : scriptPath);
const repoRoot = path.resolve(scriptDir, "..");
const aituberPackageJson = path.join(repoRoot, "organs", "expression", "aituber-kit", "package.json");
const requireFromAituber = createRequire(aituberPackageJson);

function parseArgs(argv) {
  const args = {
    url: "http://127.0.0.1:18880/projection-visual/?mode=passive&visualTest=self-mirror-baseline",
    out: path.join(repoRoot, ".cache", "agent-os", "self-mirror", timestampSlug()),
    width: 1920,
    height: 1080,
    sampleRateFps: 8,
    durationMs: 6000,
    settleMs: 900,
    readyTimeoutMs: 15000,
    waitForSelfMirrorReady: true,
    headed: false,
    browserExecutable: "",
    trigger: "none",
    triggerAtMs: 700,
    dancePayloadShape: "auto",
    analysisRunId: "vismot_run_rr003_self_mirror_browser_001",
    scenarioId: "rr003.visible_motion.self_mirror.browser.v0",
    proofLayer: "visible_motion",
    motionEventId: "mot_evt_rr003_self_mirror_browser_001",
    stimulusId: "",
    stimulusInstanceId: "mot_inst_rr003_self_mirror_browser_001",
    runtimeResultId: "",
    driverResultId: "mot_drv_rr003_self_mirror_browser_001",
    sourceRefId: "redacted_browser_self_mirror_001",
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const readValue = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`Missing value for ${arg}`);
      return argv[i];
    };

    if (arg === "--help" || arg === "-h") args.help = true;
    else if (arg === "--url") args.url = readValue();
    else if (arg === "--out") args.out = readValue();
    else if (arg === "--width") args.width = Number(readValue());
    else if (arg === "--height") args.height = Number(readValue());
    else if (arg === "--sample-rate-fps") args.sampleRateFps = Number(readValue());
    else if (arg === "--duration-ms") args.durationMs = Number(readValue());
    else if (arg === "--settle-ms") args.settleMs = Number(readValue());
    else if (arg === "--ready-timeout-ms") args.readyTimeoutMs = Number(readValue());
    else if (arg === "--skip-self-mirror-ready") args.waitForSelfMirrorReady = false;
    else if (arg === "--headed") args.headed = true;
    else if (arg === "--browser-executable") args.browserExecutable = readValue();
    else if (arg === "--trigger") args.trigger = readValue();
    else if (arg === "--trigger-at-ms") args.triggerAtMs = Number(readValue());
    else if (arg === "--dance-payload-shape") args.dancePayloadShape = readValue();
    else if (arg === "--analysis-run-id") args.analysisRunId = readValue();
    else if (arg === "--scenario-id") args.scenarioId = readValue();
    else if (arg === "--proof-layer") args.proofLayer = readValue();
    else if (arg === "--motion-event-id") args.motionEventId = readValue();
    else if (arg === "--stimulus-id") args.stimulusId = readValue();
    else if (arg === "--stimulus-instance-id") args.stimulusInstanceId = readValue();
    else if (arg === "--runtime-result-id") args.runtimeResultId = readValue();
    else if (arg === "--driver-result-id") args.driverResultId = readValue();
    else if (arg === "--source-ref-id") args.sourceRefId = readValue();
    else throw new Error(`Unknown argument: ${arg}`);
  }

  return args;
}

function usage() {
  return `Usage:
  node scripts/capture-self-mirror-frames.mjs [options]

Options:
  --url <url>                 Projection Visual URL to capture.
  --out <dir>                 Output directory for local config and temporary frames.
  --width <number>            Default: 1920
  --height <number>           Default: 1080
  --sample-rate-fps <number>  Default: 8
  --duration-ms <number>      Default: 6000
  --settle-ms <number>        Default: 900
  --ready-timeout-ms <number> Default: 15000
  --skip-self-mirror-ready    Do not wait for VRM/debug readiness before capture.
  --browser-executable <path> Optional Chrome/Edge executable fallback.
  --trigger none|context-nod|dance|expression-visible
  --trigger-at-ms <number>    Default: 700
  --dance-payload-shape auto|fixture|thought-core-dance-sequence
                              Default: auto. auto uses Thought-Core shape for
                              dance_visible_motion scenario ids.
  --runtime-result-id <id>    Optional runtime result id distinct from driver id.
                              Defaults to --driver-result-id for compatibility.
  --headed                    Show the browser window.

Security:
  Direct node execution leaves raw-browser-frames and self_mirror_browser_config.json
  in the output directory for local analyzer use. Prefer run-self-mirror-proof.ps1
  for review runs because it deletes those raw inputs by default.
`;
}

function timestampSlug(now = new Date()) {
  const pad = (value, size = 2) => String(value).padStart(size, "0");
  return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
}

function defaultWindows(args) {
  const durationMs = Math.max(1, Math.round(args.durationMs));
  const triggerAtMs = Math.max(1, Math.min(Math.round(args.triggerAtMs), durationMs - 1));
  const activeEndMs = Math.max(triggerAtMs + 1, Math.min(durationMs, triggerAtMs + 2100));
  const releaseEndMs = Math.max(activeEndMs + 1, Math.min(durationMs, activeEndMs + 1400));
  const settleEndMs = Math.max(releaseEndMs + 1, durationMs);
  return [
    { window_id: "pretrigger", start_ms: 0, end_ms: triggerAtMs },
    { window_id: "active", start_ms: triggerAtMs, end_ms: activeEndMs },
    { window_id: "release", start_ms: activeEndMs, end_ms: releaseEndMs },
    { window_id: "settle", start_ms: releaseEndMs, end_ms: settleEndMs },
  ];
}

function baseDefaultRois() {
  const guards = [
    {
      roi_id: "speech_bubble",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.22, y: 0.28, w: 0.31, h: 0.38 },
    },
    {
      roi_id: "left_hud",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.0, y: 0.02, w: 0.23, h: 0.48 },
    },
    {
      roi_id: "right_hud",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.78, y: 0.02, w: 0.22, h: 0.78 },
    },
    {
      roi_id: "bottom_controls",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.0, y: 0.78, w: 0.20, h: 0.10 },
    },
    {
      roi_id: "input_bar",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.0, y: 0.88, w: 1.0, h: 0.12 },
    },
  ];

  return {
    guards,
    avatarFaceHead: {
      roi_id: "avatar_face_head",
      kind: "avatar",
      counts_as_avatar_motion: true,
      expected_for_pass: false,
      rect_norm: { x: 0.52, y: 0.04, w: 0.15, h: 0.24 },
    },
  };
}

function defaultRois(scenarioId = "") {
  const base = baseDefaultRois();
  if (String(scenarioId).includes("dance_visible_motion")) {
    return [
      {
        roi_id: "avatar_full",
        kind: "avatar",
        counts_as_avatar_motion: true,
        expected_for_pass: true,
        rect_norm: { x: 0.37, y: 0.0, w: 0.41, h: 0.86 },
      },
      {
        roi_id: "avatar_face_head",
        kind: "avatar",
        counts_as_avatar_motion: true,
        expected_for_pass: false,
        rect_norm: { x: 0.52, y: 0.04, w: 0.17, h: 0.25 },
      },
      {
        roi_id: "avatar_torso",
        kind: "avatar",
        counts_as_avatar_motion: true,
        expected_for_pass: true,
        rect_norm: { x: 0.51, y: 0.30, w: 0.20, h: 0.38 },
      },
      {
        roi_id: "avatar_left_arm",
        kind: "avatar",
        counts_as_avatar_motion: true,
        expected_for_pass: true,
        rect_norm: { x: 0.36, y: 0.23, w: 0.17, h: 0.50 },
      },
      {
        roi_id: "avatar_right_arm",
        kind: "avatar",
        counts_as_avatar_motion: true,
        expected_for_pass: true,
        rect_norm: { x: 0.60, y: 0.23, w: 0.17, h: 0.50 },
      },
      ...base.guards,
    ];
  }

  return [
    {
      roi_id: "avatar_full",
      kind: "avatar",
      counts_as_avatar_motion: true,
      expected_for_pass: true,
      rect_norm: { x: 0.43, y: 0.0, w: 0.32, h: 0.86 },
    },
    base.avatarFaceHead,
    ...base.guards,
  ];
}

function defaultThresholds() {
  return {
    active_motion_min_score: 0.08,
    settle_motion_max_score: 0.06,
    min_consecutive_samples: 2,
  };
}

function resolveDancePayloadShape(args) {
  if (args.trigger !== "dance") return "not-dance";
  if (args.dancePayloadShape === "thought-core-dance-sequence") return args.dancePayloadShape;
  if (args.dancePayloadShape === "fixture") return args.dancePayloadShape;
  if (args.dancePayloadShape !== "auto") {
    throw new Error(`Unsupported --dance-payload-shape: ${args.dancePayloadShape}`);
  }
  return String(args.scenarioId).includes("dance_visible_motion") ? "thought-core-dance-sequence" : "fixture";
}

function motionStimulusShape(args) {
  if (args.trigger === "expression-visible") {
    return {
      payload_shape: "thought-core-expression-visible",
      stimulus_id: args.stimulusId || "expression.visible.face.browser",
      source_origin: "motion.requested",
      kind: "expression",
      payload_ref: "motion.thought_core.expression_visible.v0",
      request_mode: "apply",
      track_mask: { scope: "face_head", channels: ["expression_weight"] },
      requirements: {
        expression_profile_ref: "motion.runtime.vrm_expression_weights.v0",
        expected_visible_change: "face_expression",
        expected_roi: "avatar_face_head",
      },
    };
  }
  const dancePayloadShape = resolveDancePayloadShape(args);
  if (dancePayloadShape === "thought-core-dance-sequence") {
    return {
      payload_shape: dancePayloadShape,
      stimulus_id: args.stimulusId || "mot_stim_browser_dance_sequence",
      source_origin: "motion.requested",
      kind: "dance_sequence",
      payload_ref: "motion.thought_core.dance_sequence.v0",
      request_mode: "play",
    };
  }
  if (dancePayloadShape === "fixture") {
    return {
      payload_shape: dancePayloadShape,
      stimulus_id: args.stimulusId || "dance.sequence",
      source_origin: "self_mirror.browser_capture",
      kind: "dance",
      payload_ref: "motion.fixture.dance_sequence.v0",
      request_mode: "start",
    };
  }
  return {
    payload_shape: "context-nod-fixture",
    stimulus_id: args.stimulusId || "context.nod",
    source_origin: "self_mirror.browser_capture",
    kind: "expression",
    payload_ref: "motion.fixture.context_nod.v0",
    request_mode: "play",
  };
}

function buildMotionStimulus(args) {
  const shape = motionStimulusShape(args);
  const stimulusId = shape.stimulus_id;
  const runtimeResultId = args.runtimeResultId || args.driverResultId;
  return {
    schema_version: "motion_stimulus.v0",
    motion_event_id: args.motionEventId,
    stimulus_id: stimulusId,
    stimulus_instance_id: args.stimulusInstanceId,
    source_class: "user_command",
    source_origin: shape.source_origin,
    requested_at: new Date().toISOString(),
    kind: shape.kind,
    payload_ref: shape.payload_ref,
    request_mode: shape.request_mode,
    phase: "request",
    lifecycle_state: "requested",
    safe_visible_state: "motion_requested",
    target_model_type: "vrm",
    track_mask: shape.track_mask ?? { head: true, torso: true, arms: args.trigger === "dance" },
    requirements: shape.requirements ?? { visible_motion: true },
    trace: {
      motion_event_id: args.motionEventId,
      stimulus_id: stimulusId,
      stimulus_instance_id: args.stimulusInstanceId,
      runtime_result_id: runtimeResultId,
      driver_result_id: args.driverResultId,
      request_id: "self_mirror_browser_capture",
    },
    redaction: {
      redaction_status: "summary_only",
      shareability_class: "review_packet",
      public_safe: false,
    },
  };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function dispatchTrigger(page, args) {
  if (args.trigger === "none") return { trigger: "none", dispatched: false };
  if (args.trigger !== "context-nod" && args.trigger !== "dance" && args.trigger !== "expression-visible") {
    throw new Error(`Unsupported trigger: ${args.trigger}`);
  }
  const detail = buildMotionStimulus(args);
  await page.evaluate((payload) => {
    window.dispatchEvent(new CustomEvent("projection-visual-motion-stimulus", { detail: payload }));
  }, detail);
  return {
    trigger: args.trigger,
    dispatched: true,
    dispatched_at_ms: Math.max(0, Number(args.dispatchedAtMs ?? 0)),
    payload_shape: motionStimulusShape(args).payload_shape,
    stimulus_id: detail.stimulus_id,
    kind: detail.kind,
    request_mode: detail.request_mode,
    payload_ref: detail.payload_ref,
    source_origin: detail.source_origin,
  };
}

async function readTriggerResult(page) {
  return await page
    .evaluate(() => {
      const result = window.__projectionVisualMotionStimulusResult;
      if (!result || typeof result !== "object") return null;
      const trace = result.trace && typeof result.trace === "object" ? result.trace : {};
      const lifecycleTrace = Array.isArray(result.lifecycle_trace) ? result.lifecycle_trace : [];
      return {
        accepted: Boolean(result.accepted),
        status: String(result.status ?? "unknown"),
        reason_code: String(result.reason_code ?? "unknown"),
        safe_visible_state: String(result.safe_visible_state ?? "unknown"),
        motion_event_id: typeof result.motion_event_id === "string" ? result.motion_event_id : undefined,
        stimulus_id: typeof result.stimulus_id === "string" ? result.stimulus_id : undefined,
        stimulus_instance_id: typeof result.stimulus_instance_id === "string" ? result.stimulus_instance_id : undefined,
        runtime_result_id:
          typeof result.runtime_result_id === "string"
            ? result.runtime_result_id
            : typeof trace.runtime_result_id === "string"
              ? trace.runtime_result_id
              : undefined,
        driver_result_id:
          typeof result.driver_result_id === "string"
            ? result.driver_result_id
            : typeof trace.driver_result_id === "string"
              ? trace.driver_result_id
              : undefined,
        multi_stimulus_group_id:
          typeof result.multi_stimulus_group_id === "string"
            ? result.multi_stimulus_group_id
            : typeof trace.multi_stimulus_group_id === "string"
              ? trace.multi_stimulus_group_id
              : undefined,
        lifecycle_trace: lifecycleTrace
          .filter((entry) => entry && typeof entry === "object")
          .slice(0, 16)
          .map((entry) => ({
            state: typeof entry.state === "string" ? entry.state : undefined,
            status: typeof entry.status === "string" ? entry.status : undefined,
            reason_code: typeof entry.reason_code === "string" ? entry.reason_code : undefined,
            at_ms: Number.isFinite(entry.at_ms) ? Math.max(0, Math.round(entry.at_ms)) : undefined,
          })),
      };
    })
    .catch(() => null);
}

function safeDiagnosticString(value) {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text || text.length > 160) return null;
  const lowered = text.toLowerCase();
  if (text.includes("\\") || text.includes("/") || lowered.includes("bearer ")) return null;
  if (/(token|secret|api[_-]?key|password|credential)/i.test(text)) return null;
  return text;
}

function safeDiagnosticNumber(value) {
  if (!Number.isFinite(value)) return null;
  return Math.max(0, Math.round(value));
}

function safeCaptureRelativeMsNumber(value, maxMs = 600000) {
  if (!Number.isFinite(value)) return null;
  const rounded = Math.max(0, Math.round(value));
  return rounded <= maxMs ? rounded : null;
}

function safeDiagnosticBoolean(value) {
  return typeof value === "boolean" ? value : null;
}

function safeDiagnosticStringList(value, limit = 16) {
  if (!Array.isArray(value)) return [];
  return value
    .map((entry) => safeDiagnosticString(entry))
    .filter(Boolean)
    .slice(0, limit);
}

function copySafeStringFields(target, source, fields) {
  for (const field of fields) {
    const safe = safeDiagnosticString(source[field]);
    if (safe !== null) target[field] = safe;
  }
}

function copySafeNumberFields(target, source, fields) {
  for (const field of fields) {
    const safe = safeDiagnosticNumber(source[field]);
    if (safe !== null) target[field] = safe;
  }
}

function copySafeBooleanFields(target, source, fields) {
  for (const field of fields) {
    const safe = safeDiagnosticBoolean(source[field]);
    if (safe !== null) target[field] = safe;
  }
}

function safeDiagnosticObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

function setSafeStringField(target, field, value) {
  const safe = safeDiagnosticString(value);
  if (safe !== null) target[field] = safe;
}

function setSafeNumberField(target, field, value) {
  const safe = safeDiagnosticNumber(value);
  if (safe !== null) target[field] = safe;
}

function setSafeRelativeMsField(target, field, value) {
  const safe = safeCaptureRelativeMsNumber(value);
  if (safe !== null) target[field] = safe;
}

function setSafeBooleanField(target, field, value) {
  const safe = safeDiagnosticBoolean(value);
  if (safe !== null) target[field] = safe;
}

function flattenProjectionVisualDiagnosticsV0(raw) {
  const flat = { ...raw };
  const runtimeRefs = safeDiagnosticObject(raw.runtime_refs);
  if (runtimeRefs) {
    copySafeStringFields(flat, runtimeRefs, [
      "motion_event_id",
      "stimulus_id",
      "stimulus_instance_id",
      "runtime_result_id",
      "driver_result_id",
      "multi_stimulus_group_id",
    ]);
    setSafeStringField(flat, "runtime_status", runtimeRefs.status);
    setSafeStringField(flat, "runtime_reason_code", runtimeRefs.reason_code);
    setSafeStringField(flat, "runtime_safe_visible_state", runtimeRefs.safe_visible_state);
    setSafeBooleanField(flat, "accepted", runtimeRefs.accepted);
  }

  const eventTimeline = safeDiagnosticObject(flat.event_timeline) ? { ...flat.event_timeline } : {};
  const runtimeAnchors = safeDiagnosticObject(raw.runtime_anchors);
  if (runtimeAnchors) {
    const anchors = [
      ["request_issued", "motion_requested_at_ms"],
      ["runtime_accepted", "runtime_accepted_at_ms"],
      ["runtime_started", "runtime_started_at_ms"],
      ["result", "runtime_result_at_ms"],
    ];
    for (const [anchorId, field] of anchors) {
      const anchor = safeDiagnosticObject(runtimeAnchors[anchorId]);
      if (!anchor) continue;
      setSafeRelativeMsField(flat, field, anchor.at_ms);
      setSafeRelativeMsField(eventTimeline, field, anchor.at_ms);
    }
  }

  const driverFrameAnchor = safeDiagnosticObject(raw.driver_frame_anchor);
  if (driverFrameAnchor) {
    setSafeNumberField(flat, "driver_frame_seq", driverFrameAnchor.frame_seq);
    setSafeNumberField(flat, "driver_frame_timestamp_mono_ms", driverFrameAnchor.frame_timestamp_mono_ms);
    setSafeStringField(flat, "driver_result_id", driverFrameAnchor.driver_result_id ?? flat.driver_result_id);
    setSafeStringField(flat, "driver_observed_at", driverFrameAnchor.observed_at);
    setSafeStringField(flat, "last_driver_reason_code", driverFrameAnchor.reason_code);
    setSafeStringField(flat, "last_safe_visible_state", driverFrameAnchor.safe_visible_state);
  }

  const expressionSummary = safeDiagnosticObject(raw.expression_value_summary);
  if (expressionSummary) {
    copySafeStringFields(flat, expressionSummary, [
      "last_driver_result_id",
      "last_driver_result",
      "last_driver_reason_code",
      "last_safe_visible_state",
    ]);
    copySafeNumberFields(flat, expressionSummary, [
      "frame_applied_count",
      "last_weight_count",
      "last_frame_seq",
    ]);
    copySafeBooleanFields(flat, expressionSummary, ["expression_weight_applied"]);
    setSafeStringField(flat, "driver_result_id", expressionSummary.last_driver_result_id ?? flat.driver_result_id);
    setSafeStringField(flat, "driver_observed_at", expressionSummary.last_observed_at);
    setSafeStringField(flat, "expression_value_state", expressionSummary.last_safe_visible_state);
    const channels = safeDiagnosticStringList(expressionSummary.channel_names);
    if (channels.length) flat.expression_weight_channels = channels;
  }

  const mixedSurfaceSeparation = safeDiagnosticObject(raw.mixed_surface_separation);
  if (mixedSurfaceSeparation) {
    const surfaceClasses = [
      mixedSurfaceSeparation.avatar_canvas_surface_class,
      ...safeDiagnosticStringList(mixedSurfaceSeparation.dom_overlay_surface_classes),
    ];
    const safeSurfaceClasses = safeDiagnosticStringList(surfaceClasses);
    if (safeSurfaceClasses.length) flat.surface_classes = safeSurfaceClasses;
    setSafeStringField(flat, "avatar_canvas_surface_class", mixedSurfaceSeparation.avatar_canvas_surface_class);
    const domOverlaySurfaceClasses = safeDiagnosticStringList(mixedSurfaceSeparation.dom_overlay_surface_classes);
    if (domOverlaySurfaceClasses.length) flat.dom_overlay_surface_classes = domOverlaySurfaceClasses;
    setSafeBooleanField(
      flat,
      "dom_overlay_is_not_avatar_canvas_proof",
      mixedSurfaceSeparation.dom_overlay_is_not_avatar_canvas_proof,
    );
    setSafeBooleanField(
      flat,
      "avatar_canvas_is_not_dom_overlay_proof",
      mixedSurfaceSeparation.avatar_canvas_is_not_dom_overlay_proof,
    );
    if (
      flat.dom_overlay_is_not_avatar_canvas_proof === true &&
      flat.avatar_canvas_is_not_dom_overlay_proof === true
    ) {
      flat.surface_separation_status = "separated";
    }
  }

  if (Object.keys(eventTimeline).length) flat.event_timeline = eventTimeline;
  return flat;
}

function sanitizeProjectionVisualDiagnostics(raw) {
  if (!raw || typeof raw !== "object") return null;
  const flattened = flattenProjectionVisualDiagnosticsV0(raw);
  const safe = {
    schema_version: "projection_visual_in_page_diagnostics.v0",
    raw_frame_included: false,
    raw_screenshot_included: false,
    raw_video_included: false,
    local_path_included: false,
  };
  copySafeStringFields(safe, flattened, [
    "visual_session_id",
    "projection_visual_instance_id",
    "surface_class",
    "surface_instance_id",
    "target_surface_class",
    "target_surface_instance_id",
    "capture_target_id",
    "roi_registry_version",
    "motion_event_id",
    "stimulus_id",
    "stimulus_instance_id",
    "runtime_result_id",
    "driver_result_id",
    "multi_stimulus_group_id",
    "surface_match_status",
    "target_identity_status",
    "last_driver_result",
    "last_driver_reason_code",
    "last_safe_visible_state",
    "expression_value_state",
    "runtime_status",
    "runtime_reason_code",
    "runtime_safe_visible_state",
    "driver_observed_at",
    "last_driver_result_id",
    "avatar_canvas_surface_class",
    "surface_separation_status",
  ]);
  copySafeNumberFields(safe, flattened, [
    "frame_seq",
    "frame_timestamp_mono_ms",
    "visual_heartbeat_ms",
    "motion_requested_at_ms",
    "runtime_accepted_at_ms",
    "runtime_started_at_ms",
    "runtime_result_at_ms",
    "driver_applied_at_ms",
    "frame_applied_at_ms",
    "visual_commit_at_ms",
    "first_changed_frame_seq",
    "frame_applied_count",
    "last_weight_count",
    "last_frame_seq",
    "driver_frame_seq",
    "driver_frame_timestamp_mono_ms",
  ]);
  copySafeBooleanFields(safe, flattened, [
    "accepted",
    "same_page_or_target",
    "target_identity_match",
    "surface_match",
    "expression_weight_applied",
    "mixed_surface",
    "dom_overlay_is_not_avatar_canvas_proof",
    "avatar_canvas_is_not_dom_overlay_proof",
  ]);
  const channels = safeDiagnosticStringList(flattened.expression_weight_channels ?? flattened.changed_expression_channels);
  if (channels.length) safe.expression_weight_channels = channels;
  const surfaceClasses = safeDiagnosticStringList(flattened.surface_classes);
  if (surfaceClasses.length) safe.surface_classes = surfaceClasses;
  const domOverlaySurfaceClasses = safeDiagnosticStringList(flattened.dom_overlay_surface_classes);
  if (domOverlaySurfaceClasses.length) safe.dom_overlay_surface_classes = domOverlaySurfaceClasses;
  if (flattened.event_timeline && typeof flattened.event_timeline === "object") {
    const timeline = {};
    for (const field of [
      "motion_requested_at_ms",
      "runtime_accepted_at_ms",
      "runtime_started_at_ms",
      "runtime_result_at_ms",
      "driver_applied_at_ms",
      "frame_applied_at_ms",
      "visual_commit_at_ms",
    ]) {
      setSafeRelativeMsField(timeline, field, flattened.event_timeline[field]);
    }
    if (Object.keys(timeline).length) safe.event_timeline = timeline;
  }
  return Object.keys(safe).length > 5 ? safe : null;
}

async function readProjectionVisualDiagnostics(page) {
  return await page
    .evaluate(() => {
      const candidates = [
        window.__projectionVisualInPageDiagnostics,
        window.__projectionVisualMotionRuntimeDiagnostics,
        window.__projectionVisualSelfMirrorDiagnostics,
        window.__projectionVisualInPageDiagnosticsV0,
      ];
      const merged = {};
      for (const candidate of candidates) {
        if (candidate && typeof candidate === "object" && !Array.isArray(candidate)) {
          Object.assign(merged, candidate);
        }
      }
      return Object.keys(merged).length ? merged : null;
    })
    .then((raw) => sanitizeProjectionVisualDiagnostics(raw))
    .catch(() => null);
}

function lifecycleTraceAnchorMs(motionStimulusResult, state, durationMs) {
  const trace = Array.isArray(motionStimulusResult?.lifecycle_trace) ? motionStimulusResult.lifecycle_trace : [];
  const entry = trace.find((item) => item && item.state === state && Number.isFinite(item.at_ms));
  return entry ? safeCaptureRelativeMsNumber(entry.at_ms, Math.max(600000, Math.round(durationMs))) : null;
}

function buildEventTimeline({ triggerResult, motionStimulusResult, projectionVisualDiagnostics, durationMs }) {
  const timeline = {
    capture_started_at_ms: 0,
    bridge_dispatched_at_ms:
      Number.isFinite(triggerResult.dispatched_at_ms) && triggerResult.dispatched
        ? Math.max(0, Math.round(triggerResult.dispatched_at_ms))
        : null,
    runtime_accepted_at_ms: lifecycleTraceAnchorMs(motionStimulusResult, "runtime_accepted", durationMs),
    runtime_started_at_ms: lifecycleTraceAnchorMs(motionStimulusResult, "runtime_started", durationMs),
    runtime_result_at_ms: lifecycleTraceAnchorMs(motionStimulusResult, "result", durationMs),
    capture_ended_at_ms: Math.max(0, Math.round(durationMs)),
  };
  const diagnosticTimeline =
    projectionVisualDiagnostics && typeof projectionVisualDiagnostics.event_timeline === "object"
      ? projectionVisualDiagnostics.event_timeline
      : {};
  for (const field of [
    "motion_requested_at_ms",
    "runtime_accepted_at_ms",
    "runtime_started_at_ms",
    "runtime_result_at_ms",
    "driver_applied_at_ms",
    "frame_applied_at_ms",
    "visual_commit_at_ms",
  ]) {
    const directValue = safeCaptureRelativeMsNumber(projectionVisualDiagnostics?.[field], durationMs);
    const timelineValue = safeCaptureRelativeMsNumber(diagnosticTimeline[field], durationMs);
    if (directValue !== null) timeline[field] = directValue;
    else if (timelineValue !== null) timeline[field] = timelineValue;
  }
  return timeline;
}

function expectedVisualTestMode(urlText) {
  try {
    const value = new URL(urlText).searchParams.get("visualTest")?.trim().toLowerCase();
    if (value === "idle-neutral" || value === "self-mirror-baseline") return value;
  } catch {
    return null;
  }
  return null;
}

function safeCaptureTargetUrl(urlText) {
  try {
    const url = new URL(urlText);
    if (url.protocol !== "http:" && url.protocol !== "https:") return "redacted_non_http_url";
    if (!["127.0.0.1", "localhost", "::1"].includes(url.hostname)) return "redacted_non_local_url";
    return `${url.protocol}//${url.host}${url.pathname}${url.search}`;
  } catch {
    return "redacted_invalid_url";
  }
}

function captureTargetIdentity(args) {
  const safeUrl = safeCaptureTargetUrl(args.url);
  return {
    schema_version: "self_mirror_capture_target_identity.v0",
    capture_surface_kind: "helper_playwright_page",
    capture_target_url: safeUrl,
    trigger_target_url: safeUrl,
    same_page_or_target: true,
    page_target_id: null,
    browser_process_kind: "helper_launched",
    proof_ceiling: "helper_browser_runtime_only",
  };
}

async function readSelfMirrorReadyState(page, expectedMode) {
  return await page.evaluate((mode) => {
    const viewerDebug = window.__projectionVisualVrmViewerDebug;
    const runtimeDebug = window.__projectionVisualMotionRuntimeDebugSnapshot;
    const canvas = document.querySelector("canvas");
    const visualTestMode = viewerDebug && typeof viewerDebug === "object" ? viewerDebug.visualTestMode : null;
    const runtime = runtimeDebug && typeof runtimeDebug === "object" ? runtimeDebug : {};
    return {
      hasCanvas: Boolean(canvas),
      visualTestMode: typeof visualTestMode === "string" ? visualTestMode : null,
      expectedVisualTestMode: mode,
      visualTestModeMatches: !mode || visualTestMode === mode,
      vrmReady: runtime.vrmReady === true,
      sceneVisible: runtime.sceneVisible === true,
      frameSeq: Number.isFinite(runtime.frameSeq) ? runtime.frameSeq : 0,
    };
  }, expectedMode);
}

async function waitForSelfMirrorReady(page, args) {
  if (!args.waitForSelfMirrorReady) {
    return { skipped: true };
  }

  const expectedMode = expectedVisualTestMode(args.url);
  await page.waitForFunction(
    (mode) => {
      const viewerDebug = window.__projectionVisualVrmViewerDebug;
      const runtimeDebug = window.__projectionVisualMotionRuntimeDebugSnapshot;
      const canvas = document.querySelector("canvas");
      if (!canvas || !runtimeDebug || typeof runtimeDebug !== "object") return false;
      if (mode) {
        if (!viewerDebug || typeof viewerDebug !== "object") return false;
        if (viewerDebug.visualTestMode !== mode) return false;
      }
      return runtimeDebug.vrmReady === true && runtimeDebug.sceneVisible === true;
    },
    expectedMode,
    { timeout: args.readyTimeoutMs }
  );

  const readyState = await readSelfMirrorReadyState(page, expectedMode);
  const firstFrameSeq = readyState.frameSeq;
  await page.waitForFunction(
    (startSeq) => {
      const runtimeDebug = window.__projectionVisualMotionRuntimeDebugSnapshot;
      return (
        runtimeDebug &&
        typeof runtimeDebug === "object" &&
        Number.isFinite(runtimeDebug.frameSeq) &&
        runtimeDebug.frameSeq >= startSeq + 3
      );
    },
    firstFrameSeq,
    { timeout: Math.min(args.readyTimeoutMs, 5000) }
  );

  return await readSelfMirrorReadyState(page, expectedMode);
}

async function pathExists(filePath) {
  if (!filePath) return false;
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function browserExecutableCandidates() {
  if (process.platform !== "win32") return [];
  const programFiles = process.env.ProgramFiles || "C:\\Program Files";
  const programFilesX86 = process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)";
  const localAppData = process.env.LOCALAPPDATA || "";
  return [
    path.join(programFiles, "Google", "Chrome", "Application", "chrome.exe"),
    path.join(programFilesX86, "Google", "Chrome", "Application", "chrome.exe"),
    path.join(localAppData, "Google", "Chrome", "Application", "chrome.exe"),
    path.join(programFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
    path.join(programFilesX86, "Microsoft", "Edge", "Application", "msedge.exe"),
  ].filter(Boolean);
}

async function findBrowserExecutable(explicitPath) {
  if (explicitPath) {
    if (!(await pathExists(explicitPath))) {
      throw new Error(`Browser executable not found: ${explicitPath}`);
    }
    return explicitPath;
  }
  for (const candidate of browserExecutableCandidates()) {
    if (await pathExists(candidate)) return candidate;
  }
  return "";
}

async function launchChromium(chromium, args) {
  const launchOptions = { headless: !args.headed };
  if (args.browserExecutable) {
    return await chromium.launch({
      ...launchOptions,
      executablePath: await findBrowserExecutable(args.browserExecutable),
    });
  }
  try {
    return await chromium.launch(launchOptions);
  } catch (error) {
    const fallbackExecutable = await findBrowserExecutable("");
    if (!fallbackExecutable) throw error;
    process.stdout.write(`browser_executable_fallback=${path.basename(fallbackExecutable)}\n`);
    return await chromium.launch({
      ...launchOptions,
      executablePath: fallbackExecutable,
    });
  }
}

async function captureFrames(page, frameDir, args) {
  const frameCount = Math.max(2, Math.ceil((args.durationMs / 1000) * args.sampleRateFps));
  const intervalMs = 1000 / args.sampleRateFps;
  const framePaths = [];
  const startedAtMs = Date.now();
  let triggerResult = { trigger: args.trigger, dispatched: false };

  for (let index = 0; index < frameCount; index += 1) {
    const targetElapsedMs = Math.round(index * intervalMs);
    const elapsedMs = Date.now() - startedAtMs;
    if (!triggerResult.dispatched && args.trigger !== "none" && elapsedMs >= args.triggerAtMs) {
      triggerResult = await dispatchTrigger(page, { ...args, dispatchedAtMs: elapsedMs });
    }

    const framePath = path.join(frameDir, `frame_${String(index).padStart(4, "0")}.png`);
    await page.screenshot({ path: framePath, fullPage: false });
    framePaths.push(framePath);

    const nextTargetMs = Math.round((index + 1) * intervalMs);
    const waitMs = Math.max(0, nextTargetMs - (Date.now() - startedAtMs));
    if (waitMs > 0 && targetElapsedMs < args.durationMs) {
      await sleep(waitMs);
    }
  }

  if (!triggerResult.dispatched && args.trigger !== "none") {
    triggerResult = await dispatchTrigger(page, { ...args, dispatchedAtMs: Date.now() - startedAtMs });
  }

  return { framePaths, triggerResult };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(usage());
    return;
  }
  if (!Number.isFinite(args.sampleRateFps) || args.sampleRateFps < 1 || args.sampleRateFps > 30) {
    throw new Error("--sample-rate-fps must be between 1 and 30");
  }
  if (!Number.isFinite(args.durationMs) || args.durationMs < 500) {
    throw new Error("--duration-ms must be at least 500");
  }
  if (!Number.isFinite(args.readyTimeoutMs) || args.readyTimeoutMs < 0) {
    throw new Error("--ready-timeout-ms must be zero or greater");
  }
  if (!Number.isFinite(args.triggerAtMs) || args.triggerAtMs < 1) {
    throw new Error("--trigger-at-ms must be at least 1");
  }
  if (args.trigger !== "none" && args.triggerAtMs >= args.durationMs) {
    throw new Error("--trigger-at-ms must be less than --duration-ms when a trigger is enabled");
  }

  const { chromium } = requireFromAituber("playwright");
  const outDir = path.resolve(args.out);
  const frameDir = path.join(outDir, "raw-browser-frames");
  await fs.mkdir(frameDir, { recursive: true });

  const browser = await launchChromium(chromium, args);
  let triggerResult = { trigger: args.trigger, dispatched: false };
  let motionStimulusResult = null;
  let projectionVisualDiagnostics = null;
  let selfMirrorReady = null;
  let framePaths = [];
  try {
    const page = await browser.newPage({ viewport: { width: args.width, height: args.height } });
    await page.goto(args.url, { waitUntil: "domcontentloaded", timeout: 20000 });
    await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});
    selfMirrorReady = await waitForSelfMirrorReady(page, args);
    process.stdout.write(`self_mirror_ready=${JSON.stringify(selfMirrorReady)}\n`);
    await page.waitForTimeout(args.settleMs);
    const capture = await captureFrames(page, frameDir, args);
    framePaths = capture.framePaths;
    triggerResult = capture.triggerResult;
    motionStimulusResult = await readTriggerResult(page);
    projectionVisualDiagnostics = await readProjectionVisualDiagnostics(page);
    await page.close().catch(() => {});
  } finally {
    await browser.close().catch(() => {});
  }

  const observedRuntimeResultId =
    motionStimulusResult && typeof motionStimulusResult.runtime_result_id === "string"
      ? motionStimulusResult.runtime_result_id
      : null;
  const observedDriverResultId =
    motionStimulusResult && typeof motionStimulusResult.driver_result_id === "string"
      ? motionStimulusResult.driver_result_id
      : null;
  const plannedRuntimeResultId = args.runtimeResultId || args.driverResultId;
  const joinedDriverResultId = observedDriverResultId ?? args.driverResultId;
  const eventTimeline = buildEventTimeline({
    triggerResult,
    motionStimulusResult,
    projectionVisualDiagnostics,
    durationMs: args.durationMs,
  });
  const runtimeJoin = {
    analysis_run_id: args.analysisRunId,
    motion_event_id: args.motionEventId,
    stimulus_instance_id: args.stimulusInstanceId,
    planned_driver_result_id: args.driverResultId,
    planned_runtime_result_id: plannedRuntimeResultId,
    driver_result_id: joinedDriverResultId,
    runtime_result_id: observedRuntimeResultId,
    multi_stimulus_group_id: motionStimulusResult?.multi_stimulus_group_id ?? null,
    result_status: motionStimulusResult?.status ?? null,
    result_reason_code: motionStimulusResult?.reason_code ?? null,
    result_safe_visible_state: motionStimulusResult?.safe_visible_state ?? null,
  };

  const config = {
    analysis_run_id: args.analysisRunId,
    scenario_id: args.scenarioId,
    motion_event_id: args.motionEventId,
    stimulus_instance_id: args.stimulusInstanceId,
    driver_result_id: joinedDriverResultId,
    proof_layer: args.proofLayer,
    frame_paths: framePaths,
    source_ref: {
      kind: "browser_frame_provider",
      source_ref_id: args.sourceRefId,
    },
    sampling: {
      sample_rate_fps: args.sampleRateFps,
    },
    capture_ready: selfMirrorReady,
    event_timeline: eventTimeline,
    runtime_join: runtimeJoin,
    projection_visual_diagnostics: projectionVisualDiagnostics,
    windows: defaultWindows(args),
    rois: defaultRois(args.scenarioId),
    thresholds: defaultThresholds(),
  };
  await fs.writeFile(path.join(outDir, "self_mirror_browser_config.json"), JSON.stringify(config, null, 2) + "\n", "utf8");

  const manifest = {
    schema_version: "self_mirror_capture_manifest.v0",
    source_kind: "browser_frame_provider",
    url_label: "projection_visual",
    viewport: { width: args.width, height: args.height },
    sample_rate_fps: args.sampleRateFps,
    duration_ms: args.durationMs,
    frame_count: framePaths.length,
    target_identity: captureTargetIdentity(args),
    self_mirror_ready: selfMirrorReady,
    trigger: triggerResult,
    motion_stimulus_result: motionStimulusResult,
    projection_visual_diagnostics: projectionVisualDiagnostics,
    event_timeline: eventTimeline,
    runtime_join: runtimeJoin,
    raw_inputs_policy: {
      raw_browser_frames: "local_only_temporary_input",
      browser_config: "local_only_temporary_input",
      cleanup_owner: "run-self-mirror-proof.ps1_or_direct_caller",
      direct_node_retains_raw_inputs: true,
      share_or_commit: "prohibited",
      preferred_review_wrapper: "scripts/run-self-mirror-proof.ps1",
    },
    raw_frames_shared: false,
    raw_paths_shared: false,
    retention: "temporary_by_default",
  };
  await fs.writeFile(path.join(outDir, "self_mirror_capture_manifest.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");

  process.stdout.write("Self Mirror browser frame capture: ok\n");
  process.stdout.write(`frame_count=${framePaths.length}\n`);
  process.stdout.write("config_file=self_mirror_browser_config.json\n");
  process.stdout.write("manifest_file=self_mirror_capture_manifest.json\n");
  process.stdout.write("raw_frames_shared=false\n");
  process.stdout.write("raw_paths_shared=false\n");
  process.stdout.write("raw_inputs_retained_local_only=true\n");
  process.stdout.write("cleanup_owner=run-self-mirror-proof.ps1_or_direct_caller\n");
  process.stdout.write("do_not_share_or_commit=raw-browser-frames,self_mirror_browser_config.json\n");
}

main().catch((error) => {
  process.stderr.write(`${error?.stack ?? error}\n`);
  process.exitCode = 1;
});
