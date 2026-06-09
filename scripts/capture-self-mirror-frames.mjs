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
    url: "http://127.0.0.1:18880/projection-visual/?mode=passive&visualTest=idle-neutral",
    out: path.join(repoRoot, ".cache", "agent-os", "self-mirror", timestampSlug()),
    width: 1920,
    height: 1080,
    sampleRateFps: 8,
    durationMs: 6000,
    settleMs: 900,
    headed: false,
    browserExecutable: "",
    trigger: "none",
    triggerAtMs: 700,
    analysisRunId: "vismot_run_rr003_self_mirror_browser_001",
    scenarioId: "rr003.visible_motion.self_mirror.browser.v0",
    proofLayer: "visible_motion",
    motionEventId: "mot_evt_rr003_self_mirror_browser_001",
    stimulusInstanceId: "mot_inst_rr003_self_mirror_browser_001",
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
    else if (arg === "--headed") args.headed = true;
    else if (arg === "--browser-executable") args.browserExecutable = readValue();
    else if (arg === "--trigger") args.trigger = readValue();
    else if (arg === "--trigger-at-ms") args.triggerAtMs = Number(readValue());
    else if (arg === "--analysis-run-id") args.analysisRunId = readValue();
    else if (arg === "--scenario-id") args.scenarioId = readValue();
    else if (arg === "--proof-layer") args.proofLayer = readValue();
    else if (arg === "--motion-event-id") args.motionEventId = readValue();
    else if (arg === "--stimulus-instance-id") args.stimulusInstanceId = readValue();
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
  --browser-executable <path> Optional Chrome/Edge executable fallback.
  --trigger none|context-nod|dance
  --trigger-at-ms <number>    Default: 700
  --headed                    Show the browser window.
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

function defaultRois() {
  return [
    {
      roi_id: "avatar_full",
      kind: "avatar",
      counts_as_avatar_motion: true,
      expected_for_pass: true,
      rect_norm: { x: 0.34, y: 0.04, w: 0.34, h: 0.84 },
    },
    {
      roi_id: "avatar_face_head",
      kind: "avatar",
      counts_as_avatar_motion: true,
      expected_for_pass: true,
      rect_norm: { x: 0.43, y: 0.08, w: 0.18, h: 0.26 },
    },
    {
      roi_id: "avatar_torso",
      kind: "avatar",
      counts_as_avatar_motion: true,
      expected_for_pass: false,
      rect_norm: { x: 0.42, y: 0.33, w: 0.20, h: 0.30 },
    },
    {
      roi_id: "avatar_left_arm",
      kind: "avatar",
      counts_as_avatar_motion: true,
      expected_for_pass: false,
      rect_norm: { x: 0.33, y: 0.30, w: 0.14, h: 0.38 },
    },
    {
      roi_id: "avatar_right_arm",
      kind: "avatar",
      counts_as_avatar_motion: true,
      expected_for_pass: false,
      rect_norm: { x: 0.59, y: 0.30, w: 0.14, h: 0.38 },
    },
    {
      roi_id: "speech_bubble",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.17, y: 0.34, w: 0.34, h: 0.22 },
    },
    {
      roi_id: "left_hud",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.0, y: 0.0, w: 0.25, h: 0.72 },
    },
    {
      roi_id: "right_hud",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.75, y: 0.0, w: 0.25, h: 0.72 },
    },
    {
      roi_id: "input_bar",
      kind: "guard_ui",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.05, y: 0.90, w: 0.90, h: 0.10 },
    },
    {
      roi_id: "background_fx",
      kind: "guard_background",
      counts_as_avatar_motion: false,
      expected_for_pass: false,
      rect_norm: { x: 0.25, y: 0.0, w: 0.09, h: 0.24 },
    },
  ];
}

function defaultThresholds() {
  return {
    active_motion_min_score: 0.08,
    settle_motion_max_score: 0.06,
    min_consecutive_samples: 2,
  };
}

function safeStimulusId(trigger) {
  if (trigger === "dance") return "dance.sequence";
  return "context.nod";
}

function buildMotionStimulus(args) {
  const stimulusId = safeStimulusId(args.trigger);
  return {
    schema_version: "motion_stimulus.v0",
    motion_event_id: args.motionEventId,
    stimulus_id: stimulusId,
    stimulus_instance_id: args.stimulusInstanceId,
    source_class: "user_command",
    source_origin: "self_mirror.browser_capture",
    requested_at: new Date().toISOString(),
    kind: args.trigger === "dance" ? "dance" : "expression",
    payload_ref: args.trigger === "dance" ? "motion.fixture.dance_sequence.v0" : "motion.fixture.context_nod.v0",
    request_mode: args.trigger === "dance" ? "start" : "play",
    phase: "request",
    lifecycle_state: "requested",
    safe_visible_state: "motion_requested",
    target_model_type: "vrm",
    track_mask: { head: true, torso: true, arms: args.trigger === "dance" },
    requirements: { visible_motion: true },
    trace: {
      motion_event_id: args.motionEventId,
      stimulus_id: stimulusId,
      stimulus_instance_id: args.stimulusInstanceId,
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
  if (args.trigger !== "context-nod" && args.trigger !== "dance") {
    throw new Error(`Unsupported trigger: ${args.trigger}`);
  }
  const detail = buildMotionStimulus(args);
  await page.evaluate((payload) => {
    window.dispatchEvent(new CustomEvent("projection-visual-motion-stimulus", { detail: payload }));
  }, detail);
  return { trigger: args.trigger, dispatched: true, stimulus_id: detail.stimulus_id };
}

async function readTriggerResult(page) {
  return await page
    .evaluate(() => {
      const result = window.__projectionVisualMotionStimulusResult;
      if (!result || typeof result !== "object") return null;
      return {
        accepted: Boolean(result.accepted),
        status: String(result.status ?? "unknown"),
        reason_code: String(result.reason_code ?? "unknown"),
        safe_visible_state: String(result.safe_visible_state ?? "unknown"),
      };
    })
    .catch(() => null);
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
      triggerResult = await dispatchTrigger(page, args);
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
    triggerResult = await dispatchTrigger(page, args);
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
  let framePaths = [];
  try {
    const page = await browser.newPage({ viewport: { width: args.width, height: args.height } });
    await page.goto(args.url, { waitUntil: "domcontentloaded", timeout: 20000 });
    await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(args.settleMs);
    const capture = await captureFrames(page, frameDir, args);
    framePaths = capture.framePaths;
    triggerResult = capture.triggerResult;
    motionStimulusResult = await readTriggerResult(page);
    await page.close().catch(() => {});
  } finally {
    await browser.close().catch(() => {});
  }

  const config = {
    analysis_run_id: args.analysisRunId,
    scenario_id: args.scenarioId,
    motion_event_id: args.motionEventId,
    stimulus_instance_id: args.stimulusInstanceId,
    driver_result_id: args.driverResultId,
    proof_layer: args.proofLayer,
    frame_paths: framePaths,
    source_ref: {
      kind: "browser_frame_provider",
      source_ref_id: args.sourceRefId,
    },
    sampling: {
      sample_rate_fps: args.sampleRateFps,
    },
    windows: defaultWindows(args),
    rois: defaultRois(),
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
    trigger: triggerResult,
    motion_stimulus_result: motionStimulusResult,
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
}

main().catch((error) => {
  process.stderr.write(`${error?.stack ?? error}\n`);
  process.exitCode = 1;
});
