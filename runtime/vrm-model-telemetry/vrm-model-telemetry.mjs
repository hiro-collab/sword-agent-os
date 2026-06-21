const SCHEMA_VERSION = "vrm_model_telemetry.v0";
const PROOF_CEILING = "runtime_model_state_telemetry_summary_only";
const FULL_RELAXED_REF =
  "motion.runtime.vrm_expression_weights.full_relaxed.v0";
const DEFAULT_REF = "motion.runtime.vrm_expression_weights.v0";
const FULL_RELAXED_ID = "expression_visible_full_relaxed";
const DEFAULT_ID = "expression_visible_default";
const SAFE_ID_PATTERN = /^[A-Za-z0-9_.:-]+$/;
const SAFE_NAME_PATTERN = /^[A-Za-z0-9_.:-]+$/;
const MOTION_EVENT_PATTERN = /^mot_evt_[A-Za-z0-9_.:-]+$/;
const STIMULUS_INSTANCE_PATTERN = /^mot_inst_[A-Za-z0-9_.:-]+$/;
const RUNTIME_RESULT_PATTERN = /^mot_res_[A-Za-z0-9_.:-]+$/;
const DRIVER_RESULT_PATTERN = /^(mot_drv|driver-result)[A-Za-z0-9_.:-]*$/;
const ALLOWED_REFS = new Set([DEFAULT_REF, FULL_RELAXED_REF]);
const ALLOWED_BUCKETS = new Set(["none", "low", "medium", "high", "unknown"]);
const NON_CLAIMS = [
  "not_self_mirror_pass",
  "not_expression_visible_pass",
  "not_semantic_expression_correctness",
  "not_browser_visible_proof",
  "not_physical_or_projector_proof",
  "not_release_or_final_rr003",
  "not_roi_or_threshold_authority",
  "not_command_authority",
  "not_raw_media_publication",
];

function safeName(value, fallback = "") {
  const text = String(value ?? "").trim();
  if (text && text.length <= 80 && SAFE_NAME_PATTERN.test(text)) return text;
  return fallback;
}

function safeIdFragment(value, fallback = "unknown") {
  const text = String(value ?? "")
    .trim()
    .replace(/[^A-Za-z0-9_.:-]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return text && SAFE_ID_PATTERN.test(text) ? text : fallback;
}

function safeUnitNumber(value, fallback = 0) {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(0, Math.min(1, Number(value.toFixed(6))));
}

function safeMs(value, fallback = 0, maxMs = 60000) {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(0, Math.min(maxMs, Math.round(value)));
}

function safeNameList(value, limit = 80) {
  if (!Array.isArray(value)) return [];
  const names = [];
  for (const entry of value) {
    const safe = safeName(entry);
    if (safe) names.push(safe);
    if (names.length >= limit) break;
  }
  return names;
}

function uniqueSorted(values) {
  return [...new Set(values)].sort((a, b) => a.localeCompare(b));
}

function bucketForUnitValue(value) {
  if (!Number.isFinite(value)) return "unknown";
  if (value <= 0) return "none";
  if (value < 0.34) return "low";
  if (value < 0.67) return "medium";
  return "high";
}

function meanBucket(samples) {
  const numeric = samples
    .map((sample) => sample.numeric_value)
    .filter((value) => Number.isFinite(value));
  if (!numeric.length) {
    return samples.some((sample) => sample.changed) ? "unknown" : "none";
  }
  const mean = numeric.reduce((sum, value) => sum + value, 0) / numeric.length;
  return bucketForUnitValue(mean);
}

function maxBucket(samples) {
  const order = ["none", "low", "medium", "high", "unknown"];
  let best = "none";
  for (const sample of samples) {
    if (order.indexOf(sample.value_bucket) > order.indexOf(best)) {
      best = sample.value_bucket;
    }
  }
  return best;
}

function minBucket(samples) {
  const order = ["none", "low", "medium", "high", "unknown"];
  let best = "unknown";
  for (const sample of samples) {
    if (order.indexOf(sample.value_bucket) < order.indexOf(best)) {
      best = sample.value_bucket;
    }
  }
  return best;
}

function expressionProfileRefFromDiagnostics(diagnostics, triggerResult) {
  const direct = safeName(diagnostics?.expression_profile_ref);
  if (ALLOWED_REFS.has(direct)) return direct;
  const triggerRef = safeName(triggerResult?.expression_profile_ref);
  if (ALLOWED_REFS.has(triggerRef)) return triggerRef;
  return triggerResult?.expression_profile === "full-relaxed"
    ? FULL_RELAXED_REF
    : DEFAULT_REF;
}

function expressionProfileIdFromDiagnostics(diagnostics, triggerResult) {
  const direct = safeName(diagnostics?.expression_profile_id);
  if (direct) return direct;
  const triggerId = safeName(triggerResult?.expression_profile_id);
  if (triggerId) return triggerId;
  return triggerResult?.expression_profile === "full-relaxed"
    ? FULL_RELAXED_ID
    : DEFAULT_ID;
}

function shouldBuildTelemetry({ triggerResult, projectionVisualDiagnostics }) {
  if (triggerResult?.trigger === "expression-visible") return true;
  if (safeName(projectionVisualDiagnostics?.expression_profile_ref))
    return true;
  if (
    safeNameList(projectionVisualDiagnostics?.expression_weight_channels).length
  )
    return true;
  return false;
}

function buildExpressionSeries({
  appliedChannels,
  changed,
  appliedAtMs,
  endMs,
  targetWeight,
  lastWeight,
}) {
  const channels = appliedChannels.length ? appliedChannels : ["expression"];
  return channels.slice(0, 12).map((channel, index) => {
    const channelName = safeName(channel, `channel_${index + 1}`);
    const appliedBucket = changed ? bucketForUnitValue(targetWeight) : "none";
    const lastBucket = changed ? bucketForUnitValue(lastWeight) : "none";
    const samples = [
      {
        t_ms: 0,
        numeric_value: 0,
        value_bucket: "none",
        changed: false,
      },
      {
        t_ms: appliedAtMs,
        numeric_value: changed ? targetWeight : 0,
        value_bucket: appliedBucket,
        changed,
      },
      {
        t_ms: endMs,
        numeric_value: changed ? lastWeight : 0,
        value_bucket: lastBucket,
        changed,
      },
    ];
    return {
      series_id: `vrm_series_${safeIdFragment(channelName)}_${index + 1}`,
      track: "face",
      metric_kind: "expression_weight",
      channel_name: channelName,
      source: "vrm_expression_manager",
      samples,
    };
  });
}

export function buildVrmModelTelemetrySummary({
  analysisRunId,
  capturedAt = new Date().toISOString(),
  durationMs = 6000,
  triggerResult = null,
  runtimeJoin = null,
  projectionVisualDiagnostics = null,
  eventTimeline = null,
} = {}) {
  if (!shouldBuildTelemetry({ triggerResult, projectionVisualDiagnostics })) {
    return null;
  }

  const diagnostics = projectionVisualDiagnostics ?? {};
  const timeline = eventTimeline ?? diagnostics.event_timeline ?? {};
  const endMs = safeMs(timeline.capture_ended_at_ms, durationMs);
  const appliedAtMs = safeMs(
    timeline.driver_applied_at_ms ?? timeline.frame_applied_at_ms,
    safeMs(triggerResult?.dispatched_at_ms, Math.min(700, endMs)),
    endMs,
  );
  const expressionProfileRef = expressionProfileRefFromDiagnostics(
    diagnostics,
    triggerResult,
  );
  const expressionProfileId = expressionProfileIdFromDiagnostics(
    diagnostics,
    triggerResult,
  );
  const requestedChannels = uniqueSorted(
    safeNameList(diagnostics.expression_weight_channels),
  );
  const appliedChannels = uniqueSorted(
    safeNameList(diagnostics.expression_applied_channels),
  );
  const droppedChannels = uniqueSorted(
    safeNameList(diagnostics.expression_dropped_channels),
  );
  const requestedChannelCount = Number.isFinite(
    diagnostics.requested_channel_count,
  )
    ? diagnostics.requested_channel_count
    : requestedChannels.length;
  const appliedChannelCount = Number.isFinite(diagnostics.applied_channel_count)
    ? diagnostics.applied_channel_count
    : appliedChannels.length;
  const droppedChannelCount = Number.isFinite(diagnostics.dropped_channel_count)
    ? diagnostics.dropped_channel_count
    : droppedChannels.length;
  const expressionWeightApplied =
    diagnostics.expression_weight_applied === true && appliedChannelCount > 0;
  const targetWeight = safeUnitNumber(
    diagnostics.target_weight_max,
    expressionWeightApplied ? 1 : 0,
  );
  const lastWeight = safeUnitNumber(
    diagnostics.last_weight_max,
    expressionWeightApplied ? targetWeight : 0,
  );
  const series = buildExpressionSeries({
    appliedChannels,
    changed: expressionWeightApplied,
    appliedAtMs,
    endMs,
    targetWeight,
    lastWeight,
  });
  const allSamples = series.flatMap((entry) => entry.samples);
  const changed = expressionWeightApplied;
  const driverResultId = safeName(runtimeJoin?.driver_result_id);
  const runtimeResultId = safeName(runtimeJoin?.runtime_result_id);

  const correlation = {
    target_model_type: "vrm",
    expression_profile_ref: expressionProfileRef,
    expression_profile_id: expressionProfileId,
  };
  const motionEventId = safeName(runtimeJoin?.motion_event_id);
  if (MOTION_EVENT_PATTERN.test(motionEventId)) {
    correlation.motion_event_id = motionEventId;
  }
  const stimulusInstanceId = safeName(runtimeJoin?.stimulus_instance_id);
  if (STIMULUS_INSTANCE_PATTERN.test(stimulusInstanceId)) {
    correlation.stimulus_instance_id = stimulusInstanceId;
  }
  if (RUNTIME_RESULT_PATTERN.test(runtimeResultId)) {
    correlation.runtime_result_id = runtimeResultId;
  }
  if (DRIVER_RESULT_PATTERN.test(driverResultId)) {
    correlation.driver_result_id = driverResultId;
  }

  return {
    schema_version: SCHEMA_VERSION,
    telemetry_id: `vrm_tel_${safeIdFragment(analysisRunId, "runtime")}`,
    captured_at: capturedAt,
    proof_ceiling: PROOF_CEILING,
    correlation,
    sample_window: {
      start_ms: 0,
      end_ms: endMs,
      sample_count: allSamples.length,
      decimation: "event_edges",
    },
    series,
    summary: {
      requested_channel_count: requestedChannelCount,
      applied_channel_count: appliedChannelCount,
      dropped_channel_count: droppedChannelCount,
      requested_channel_names: requestedChannels,
      applied_channel_names: appliedChannels,
      dropped_channel_names: droppedChannels,
      track_summaries: [
        {
          track: "face",
          metric_kind: "expression_weight",
          changed,
          min_bucket: minBucket(allSamples),
          max_bucket: maxBucket(allSamples),
          mean_bucket: meanBucket(allSamples),
          confidence: changed ? 0.9 : 0.6,
        },
      ],
    },
    redaction: {
      redaction_status: "summary_only",
      shareability_class: "runtime_model_state_telemetry_summary",
      raw_media_shared: false,
      raw_path_shared: false,
      raw_asset_name_shared: false,
      raw_browser_storage_shared: false,
    },
    safety: {
      command_authority: false,
      roi_or_threshold_authority: false,
      self_mirror_authority: false,
      semantic_expression_authority: false,
      physical_proof_authority: false,
      provider_payload_shared: false,
      home_assistant_route: false,
      private_device_value_shared: false,
    },
    non_claims: NON_CLAIMS,
  };
}

function assertConst(errors, value, expected, path) {
  if (value !== expected) errors.push(`${path} must be ${expected}`);
}

function assertBooleanFalse(errors, value, path) {
  if (value !== false) errors.push(`${path} must be false`);
}

function assertPattern(errors, value, pattern, path, required = false) {
  if (value === undefined || value === null || value === "") {
    if (required) errors.push(`${path} is required`);
    return;
  }
  if (typeof value !== "string" || !pattern.test(value)) {
    errors.push(`${path} does not match the required safe pattern`);
  }
}

function assertBucket(errors, value, path) {
  if (!ALLOWED_BUCKETS.has(value)) errors.push(`${path} has invalid bucket`);
}

export function validateVrmModelTelemetrySummary(payload) {
  const errors = [];
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return ["payload must be an object"];
  }
  assertConst(errors, payload.schema_version, SCHEMA_VERSION, "schema_version");
  assertPattern(
    errors,
    payload.telemetry_id,
    /^vrm_tel_[A-Za-z0-9_.:-]+$/,
    "telemetry_id",
    true,
  );
  if (
    typeof payload.captured_at !== "string" ||
    Number.isNaN(Date.parse(payload.captured_at))
  ) {
    errors.push("captured_at must be an RFC3339 date-time string");
  }
  assertConst(errors, payload.proof_ceiling, PROOF_CEILING, "proof_ceiling");
  const correlation = payload.correlation;
  if (!correlation || typeof correlation !== "object") {
    errors.push("correlation is required");
  } else {
    assertConst(
      errors,
      correlation.target_model_type,
      "vrm",
      "correlation.target_model_type",
    );
    if (!ALLOWED_REFS.has(correlation.expression_profile_ref)) {
      errors.push("correlation.expression_profile_ref is not allowed");
    }
    assertPattern(
      errors,
      correlation.expression_profile_id,
      /^[a-z][a-z0-9_.:-]*$/,
      "correlation.expression_profile_id",
      true,
    );
    assertPattern(
      errors,
      correlation.motion_event_id,
      MOTION_EVENT_PATTERN,
      "correlation.motion_event_id",
    );
    assertPattern(
      errors,
      correlation.stimulus_instance_id,
      STIMULUS_INSTANCE_PATTERN,
      "correlation.stimulus_instance_id",
    );
    assertPattern(
      errors,
      correlation.runtime_result_id,
      RUNTIME_RESULT_PATTERN,
      "correlation.runtime_result_id",
    );
    assertPattern(
      errors,
      correlation.driver_result_id,
      DRIVER_RESULT_PATTERN,
      "correlation.driver_result_id",
    );
  }
  const sampleWindow = payload.sample_window;
  if (!sampleWindow || typeof sampleWindow !== "object") {
    errors.push("sample_window is required");
  } else {
    for (const field of ["start_ms", "end_ms", "sample_count"]) {
      if (!Number.isInteger(sampleWindow[field])) {
        errors.push(`sample_window.${field} must be an integer`);
      }
    }
    if (
      !["none", "fixed_interval", "event_edges", "bucketed"].includes(
        sampleWindow.decimation,
      )
    ) {
      errors.push("sample_window.decimation is invalid");
    }
  }
  if (!Array.isArray(payload.series) || !payload.series.length) {
    errors.push("series must contain at least one entry");
  } else if (payload.series.length > 24) {
    errors.push("series must contain at most 24 entries");
  } else {
    payload.series.forEach((series, index) => {
      assertPattern(
        errors,
        series?.series_id,
        /^vrm_series_[A-Za-z0-9_.:-]+$/,
        `series[${index}].series_id`,
        true,
      );
      if (
        ![
          "face",
          "mouth",
          "eyes",
          "gaze",
          "head",
          "neck",
          "spine",
          "body_root",
        ].includes(series?.track)
      ) {
        errors.push(`series[${index}].track is invalid`);
      }
      if (
        ![
          "expression_weight",
          "expression_delta_bucket",
          "morph_delta_bucket",
          "bone_rotation_delta_bucket",
          "bone_position_delta_bucket",
          "gaze_delta_bucket",
        ].includes(series?.metric_kind)
      ) {
        errors.push(`series[${index}].metric_kind is invalid`);
      }
      if (
        ![
          "vrm_expression_manager",
          "vrm_runtime_adapter",
          "motion_mixer",
          "driver_summary",
        ].includes(series?.source)
      ) {
        errors.push(`series[${index}].source is invalid`);
      }
      if (!Array.isArray(series?.samples) || !series.samples.length) {
        errors.push(`series[${index}].samples must be non-empty`);
      } else if (series.samples.length > 240) {
        errors.push(`series[${index}].samples exceeds 240`);
      } else {
        series.samples.forEach((sample, sampleIndex) => {
          if (!Number.isInteger(sample?.t_ms)) {
            errors.push(
              `series[${index}].samples[${sampleIndex}].t_ms invalid`,
            );
          }
          assertBucket(
            errors,
            sample?.value_bucket,
            `series[${index}].samples[${sampleIndex}].value_bucket`,
          );
          if (typeof sample?.changed !== "boolean") {
            errors.push(
              `series[${index}].samples[${sampleIndex}].changed must be boolean`,
            );
          }
        });
      }
    });
  }
  const summary = payload.summary;
  if (!summary || typeof summary !== "object") {
    errors.push("summary is required");
  } else {
    for (const field of [
      "requested_channel_count",
      "applied_channel_count",
      "dropped_channel_count",
    ]) {
      if (!Number.isInteger(summary[field])) {
        errors.push(`summary.${field} must be an integer`);
      }
    }
    if (
      !Array.isArray(summary.track_summaries) ||
      !summary.track_summaries.length
    ) {
      errors.push("summary.track_summaries must be non-empty");
    } else {
      summary.track_summaries.forEach((trackSummary, index) => {
        assertBucket(
          errors,
          trackSummary.min_bucket,
          `track_summaries[${index}].min_bucket`,
        );
        assertBucket(
          errors,
          trackSummary.max_bucket,
          `track_summaries[${index}].max_bucket`,
        );
        assertBucket(
          errors,
          trackSummary.mean_bucket,
          `track_summaries[${index}].mean_bucket`,
        );
        if (typeof trackSummary.changed !== "boolean") {
          errors.push(`track_summaries[${index}].changed must be boolean`);
        }
        if (
          !Number.isFinite(trackSummary.confidence) ||
          trackSummary.confidence < 0 ||
          trackSummary.confidence > 1
        ) {
          errors.push(`track_summaries[${index}].confidence must be 0..1`);
        }
      });
    }
  }
  if (!payload.redaction || typeof payload.redaction !== "object") {
    errors.push("redaction is required");
  } else {
    assertConst(
      errors,
      payload.redaction.redaction_status,
      "summary_only",
      "redaction.redaction_status",
    );
    assertConst(
      errors,
      payload.redaction.shareability_class,
      "runtime_model_state_telemetry_summary",
      "redaction.shareability_class",
    );
    for (const field of [
      "raw_media_shared",
      "raw_path_shared",
      "raw_asset_name_shared",
      "raw_browser_storage_shared",
    ]) {
      assertBooleanFalse(
        errors,
        payload.redaction[field],
        `redaction.${field}`,
      );
    }
  }
  if (!payload.safety || typeof payload.safety !== "object") {
    errors.push("safety is required");
  } else {
    for (const field of [
      "command_authority",
      "roi_or_threshold_authority",
      "self_mirror_authority",
      "semantic_expression_authority",
      "physical_proof_authority",
      "provider_payload_shared",
      "home_assistant_route",
      "private_device_value_shared",
    ]) {
      assertBooleanFalse(errors, payload.safety[field], `safety.${field}`);
    }
  }
  if (!Array.isArray(payload.non_claims) || !payload.non_claims.length) {
    errors.push("non_claims must be non-empty");
  } else {
    for (const claim of NON_CLAIMS) {
      if (!payload.non_claims.includes(claim)) {
        errors.push(`non_claims missing ${claim}`);
      }
    }
  }
  return errors;
}

export const VRM_MODEL_TELEMETRY_SCHEMA_VERSION = SCHEMA_VERSION;
