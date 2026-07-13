import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  dispatchDanceStop,
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

test("dance lifecycle capture schedules one same-page stop with fixed safe fields", async () => {
  const source = await readFile(capturePath, "utf8");
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
