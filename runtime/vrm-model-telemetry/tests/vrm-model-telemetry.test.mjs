import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import {
  buildVrmModelTelemetrySummary,
  validateVrmModelTelemetrySummary,
  VRM_MODEL_TELEMETRY_SCHEMA_VERSION,
} from "../vrm-model-telemetry.mjs";

const schema = JSON.parse(
  fs.readFileSync(
    new URL(
      "../../../contracts/vrm_model_telemetry/vrm_model_telemetry.v0.schema.json",
      import.meta.url,
    ),
    "utf8",
  ),
);

test("builds a full-relaxed expression telemetry packet from runtime diagnostics", () => {
  const payload = buildVrmModelTelemetrySummary({
    analysisRunId: "vismot_run_rr003_full_relaxed_profile_browser_001",
    capturedAt: "2026-06-21T00:00:00Z",
    durationMs: 6000,
    triggerResult: {
      trigger: "expression-visible",
      dispatched: true,
      dispatched_at_ms: 750,
      expression_profile: "full-relaxed",
      expression_profile_ref:
        "motion.runtime.vrm_expression_weights.full_relaxed.v0",
      expression_profile_id: "expression_visible_full_relaxed",
    },
    runtimeJoin: {
      motion_event_id: "mot_evt_rr003_full_relaxed_001",
      stimulus_instance_id: "mot_inst_rr003_full_relaxed_001",
      runtime_result_id: "mot_res_rr003_full_relaxed_001",
      driver_result_id: "driver-result-30",
    },
    eventTimeline: {
      driver_applied_at_ms: 812,
      frame_applied_at_ms: 820,
      capture_ended_at_ms: 6000,
    },
    projectionVisualDiagnostics: {
      expression_profile_ref:
        "motion.runtime.vrm_expression_weights.full_relaxed.v0",
      expression_profile_id: "expression_visible_full_relaxed",
      expression_weight_applied: true,
      requested_channel_count: 6,
      applied_channel_count: 2,
      dropped_channel_count: 4,
      target_weight_max: 1,
      last_weight_max: 1,
      expression_weight_channels: [
        "Fun",
        "Joy",
        "fun",
        "happy",
        "joy",
        "relaxed",
      ],
      expression_applied_channels: ["happy", "relaxed"],
      expression_dropped_channels: ["Fun", "Joy", "fun", "joy"],
    },
  });

  assert.equal(payload.schema_version, VRM_MODEL_TELEMETRY_SCHEMA_VERSION);
  assert.equal(
    payload.correlation.expression_profile_ref,
    "motion.runtime.vrm_expression_weights.full_relaxed.v0",
  );
  assert.equal(
    payload.correlation.expression_profile_id,
    "expression_visible_full_relaxed",
  );
  assert.equal(payload.summary.requested_channel_count, 6);
  assert.equal(payload.summary.applied_channel_count, 2);
  assert.equal(payload.summary.dropped_channel_count, 4);
  assert.deepEqual(payload.summary.applied_channel_names, ["happy", "relaxed"]);
  assert.equal(payload.summary.track_summaries[0].changed, true);
  assert.equal(payload.redaction.raw_media_shared, false);
  assert.equal(payload.redaction.raw_path_shared, false);
  assert.equal(payload.safety.self_mirror_authority, false);
  assert.equal(payload.safety.roi_or_threshold_authority, false);
  assert.deepEqual(validateVrmModelTelemetrySummary(payload), []);
});

test("keeps non-expression captures out of the VRM telemetry surface", () => {
  const payload = buildVrmModelTelemetrySummary({
    triggerResult: { trigger: "context-nod", dispatched: true },
    projectionVisualDiagnostics: { frame_applied_count: 1 },
  });

  assert.equal(payload, null);
});

test("rejects unknown expression profile refs during contract validation", () => {
  const payload = buildVrmModelTelemetrySummary({
    analysisRunId: "vismot_run_rr003_full_relaxed_profile_browser_001",
    capturedAt: "2026-06-21T00:00:00Z",
    triggerResult: {
      trigger: "expression-visible",
      dispatched: true,
      expression_profile: "full-relaxed",
    },
    projectionVisualDiagnostics: {
      expression_profile_ref:
        "motion.runtime.vrm_expression_weights.full_relaxed.v0",
      expression_profile_id: "expression_visible_full_relaxed",
      expression_weight_applied: true,
      applied_channel_count: 1,
      expression_applied_channels: ["happy"],
    },
  });
  payload.correlation.expression_profile_ref =
    "motion.runtime.vrm_expression_weights.unknown.v0";

  assert.match(
    validateVrmModelTelemetrySummary(payload).join("\n"),
    /expression_profile_ref is not allowed/,
  );
});

test("the committed schema still locks the expected telemetry constants", () => {
  assert.equal(
    schema.properties.schema_version.const,
    VRM_MODEL_TELEMETRY_SCHEMA_VERSION,
  );
  assert.equal(
    schema.properties.proof_ceiling.const,
    "runtime_model_state_telemetry_summary_only",
  );
  assert.equal(schema.$defs.redaction.properties.raw_media_shared.const, false);
  assert.equal(schema.$defs.redaction.properties.raw_path_shared.const, false);
  assert.equal(
    schema.$defs.safety.properties.self_mirror_authority.const,
    false,
  );
  assert.equal(
    schema.$defs.safety.properties.roi_or_threshold_authority.const,
    false,
  );
});
