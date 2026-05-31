#!/usr/bin/env node

import { createRequire } from "node:module";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const scriptPath = new URL(import.meta.url).pathname;
const scriptDir = path.dirname(process.platform === "win32" && scriptPath.startsWith("/") ? scriptPath.slice(1) : scriptPath);
const repoRoot = path.resolve(scriptDir, "..");
const workspaceRoot = path.resolve(repoRoot, "..");
const aituberPackageJson = path.join(repoRoot, "organs", "expression", "aituber-kit", "package.json");
const requireFromAituber = createRequire(aituberPackageJson);

function parseArgs(argv) {
  const args = {
    preset: "rr001",
    out: null,
    headed: false,
    skipUnavailable: true,
    timeoutMs: 15000,
    settleMs: 800,
    launcherUrl: "http://127.0.0.1:8799/",
    aituberUrl: "http://127.0.0.1:18880/",
    displayUrl: "http://127.0.0.1:18889/",
    only: null,
    targetsFile: null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const readValue = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`Missing value for ${arg}`);
      return argv[i];
    };

    if (arg === "--help" || arg === "-h") args.help = true;
    else if (arg === "--preset") args.preset = readValue();
    else if (arg === "--out") args.out = readValue();
    else if (arg === "--headed") args.headed = true;
    else if (arg === "--fail-on-missing") args.skipUnavailable = false;
    else if (arg === "--skip-unavailable") args.skipUnavailable = true;
    else if (arg === "--timeout-ms") args.timeoutMs = Number(readValue());
    else if (arg === "--settle-ms") args.settleMs = Number(readValue());
    else if (arg === "--launcher-url") args.launcherUrl = readValue();
    else if (arg === "--aituber-url") args.aituberUrl = readValue();
    else if (arg === "--display-url") args.displayUrl = readValue();
    else if (arg === "--only") args.only = readValue().split(",").map((x) => x.trim()).filter(Boolean);
    else if (arg === "--targets-file") args.targetsFile = readValue();
    else throw new Error(`Unknown argument: ${arg}`);
  }

  return args;
}

function usage() {
  return `Usage:
  node scripts/capture-ui-review-screenshots.mjs [options]

Options:
  --preset rr001|launcher|projection|display
  --out <dir>                 Output directory. Defaults to ../local/review-screenshots/<date>/design-gui/auto-<time>
  --only <id,id>              Capture only matching target ids
  --targets-file <json>       Custom target list. [{ "id": "...", "url": "...", "width": 1366, "height": 768 }]
  --launcher-url <url>        Default: http://127.0.0.1:8799/
  --aituber-url <url>         Default: http://127.0.0.1:18880/
  --display-url <url>         Default: http://127.0.0.1:18889/
  --headed                    Show the browser
  --fail-on-missing           Exit non-zero if a target cannot be captured
  --timeout-ms <number>       Default: 15000
  --settle-ms <number>        Default: 800
`;
}

function dateParts(now = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return {
    date: `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`,
    time: `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`,
  };
}

function defaultOutDir() {
  const { date, time } = dateParts();
  return path.join(workspaceRoot, "local", "review-screenshots", date, "design-gui", `auto-${time}`);
}

function joinUrl(base, suffix) {
  const normalized = base.endsWith("/") ? base.slice(0, -1) : base;
  return `${normalized}${suffix}`;
}

function presetTargets(args) {
  const targets = {
    launcher: [
      { id: "launcher-1366x768", surface: "Launcher", url: args.launcherUrl, width: 1366, height: 768 },
      { id: "launcher-1920x1080", surface: "Launcher", url: args.launcherUrl, width: 1920, height: 1080 },
    ],
    projection: [
      { id: "projection-operator-1920x1080", surface: "Projection Visual operator", url: joinUrl(args.aituberUrl, "/projection-visual"), width: 1920, height: 1080 },
      { id: "projection-passive-1920x1080", surface: "Passive Projection", url: joinUrl(args.aituberUrl, "/projection-visual?mode=passive"), width: 1920, height: 1080 },
      { id: "projection-passive-hud0-1920x1080", surface: "Passive Projection HUD hidden", url: joinUrl(args.aituberUrl, "/projection-visual?mode=passive&hud=0"), width: 1920, height: 1080 },
    ],
    display: [
      { id: "aituber-root-1366x768", surface: "AITuber root", url: args.aituberUrl, width: 1366, height: 768 },
      { id: "display-gui-1366x768", surface: "Display Runtime GUI", url: args.displayUrl, width: 1366, height: 768 },
    ],
  };

  if (args.preset === "rr001") return [...targets.launcher, ...targets.display, ...targets.projection];
  if (targets[args.preset]) return targets[args.preset];
  throw new Error(`Unknown preset: ${args.preset}`);
}

async function loadTargets(args) {
  const targets = args.targetsFile
    ? JSON.parse(await fs.readFile(path.resolve(args.targetsFile), "utf8"))
    : presetTargets(args);
  const filtered = args.only ? targets.filter((target) => args.only.includes(target.id)) : targets;
  return filtered.map((target) => {
    if (!target.id || !target.url || !target.width || !target.height) {
      throw new Error(`Invalid target: ${JSON.stringify(target)}`);
    }
    return target;
  });
}

function toBrowserUrl(rawUrl) {
  if (/^https?:\/\//i.test(rawUrl) || /^file:\/\//i.test(rawUrl)) return rawUrl;
  return pathToFileURL(path.resolve(rawUrl)).href;
}

function safeFileName(name) {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
}

function cleanNote(value) {
  return String(value ?? "")
    .replace(/\u001b\[[0-9;]*m/g, "")
    .replace(/\|/g, "\\|")
    .replace(/\s+/g, " ")
    .slice(0, 220);
}

async function captureTarget(browser, target, outDir, args) {
  const page = await browser.newPage({ viewport: { width: target.width, height: target.height } });
  const fileName = `${safeFileName(target.id)}.png`;
  const outputPath = path.join(outDir, fileName);
  const started = new Date().toISOString();

  try {
    const url = toBrowserUrl(target.url);
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: args.timeoutMs });
    await page.waitForLoadState("networkidle", { timeout: Math.min(args.timeoutMs, 5000) }).catch(() => {});
    await page.waitForTimeout(args.settleMs);
    await page.screenshot({ path: outputPath, fullPage: false });
    return {
      ...target,
      status: "captured",
      file: outputPath,
      started,
      note: "no automated redaction applied",
    };
  } catch (error) {
    if (!args.skipUnavailable) throw error;
    return {
      ...target,
      status: "missing",
      file: "",
      started,
      note: cleanNote(error?.message ?? error),
    };
  } finally {
    await page.close().catch(() => {});
  }
}

function relativeForIndex(filePath) {
  if (!filePath) return "";
  return path.relative(workspaceRoot, filePath).replaceAll("\\", "/");
}

async function writeIndex(outDir, results, args) {
  const lines = [
    "# UI Review Screenshot Capture",
    "",
    `- Created: ${new Date().toISOString()}`,
    `- Preset: ${args.preset}`,
    "- Owner/thread: design-gui",
    "- Redaction: raw local review capture; do not commit screenshots without separate redaction review.",
    "",
    "| Surface | Target id | URL | Viewport | Status | Local path | Notes |",
    "| --- | --- | --- | --- | --- | --- | --- |",
  ];

  for (const result of results) {
    lines.push(`| ${result.surface ?? result.id} | ${result.id} | \`${result.url}\` | ${result.width}x${result.height} | ${result.status} | \`${relativeForIndex(result.file)}\` | ${result.note} |`);
  }

  lines.push("");
  lines.push("## Suggested Review Use");
  lines.push("");
  lines.push("- Use these captures for local design review only.");
  lines.push("- Treat `missing` rows as current-capture gaps, not visual-pass evidence.");
  lines.push("- If a capture will be shared outside the local workspace, create a separately redacted copy.");
  lines.push("");

  await fs.writeFile(path.join(outDir, "index.md"), lines.join("\n"), "utf8");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(usage());
    return;
  }

  const { chromium } = requireFromAituber("playwright");
  const outDir = path.resolve(args.out ?? defaultOutDir());
  await fs.mkdir(outDir, { recursive: true });

  const targets = await loadTargets(args);
  if (!targets.length) throw new Error("No capture targets selected.");

  const browser = await chromium.launch({ headless: !args.headed });
  const results = [];
  try {
    for (const target of targets) {
      process.stdout.write(`Capturing ${target.id} (${target.width}x${target.height})...\n`);
      results.push(await captureTarget(browser, target, outDir, args));
    }
  } finally {
    await browser.close().catch(() => {});
  }

  await writeIndex(outDir, results, args);
  const captured = results.filter((result) => result.status === "captured").length;
  const missing = results.length - captured;
  process.stdout.write(`Done: ${captured} captured, ${missing} missing.\n`);
  process.stdout.write(`Index: ${path.join(outDir, "index.md")}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error?.stack ?? error}\n`);
  process.exitCode = 1;
});
