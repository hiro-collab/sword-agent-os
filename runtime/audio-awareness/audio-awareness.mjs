const SCHEMA_VERSION = "audio_awareness_summary.v0";
const SOURCE_STATIC_PROOF_CEILING =
  "audio_awareness_source_static_summary_only";
const PC_OUTPUT_PROOF_CEILING = "pc_output_audio_observed_summary_only";
const MICROPHONE_PROOF_CEILING = "microphone_audio_observed_summary_only";
const CORRELATION_PROOF_CEILING =
  "pc_output_microphone_correlation_summary_only";
const DEFAULT_SILENCE_THRESHOLD = 0.001;
const DEFAULT_AUDIO_PRESENT_DBFS = -60;
const SAFE_ID_PATTERN = /^[a-z][a-z0-9_.:-]*$/;
const SUMMARY_ID_PATTERN = /^aud_sum_[A-Za-z0-9_.:-]+$/;
const SAFE_REF_PATTERN =
  /^(event|summary|audio|adapter|source):[A-Za-z0-9_.:-]+$/;
const UNSAFE_REF_TEXT_PATTERN =
  /\.(wav|mp3|mp4|m4a|flac|ogg|webm)$|localStorage|sessionStorage|browser-storage|browser_storage|provider_payload|provider_id|transcript_body/;
const CHANNEL_KINDS = new Set([
  "pc_output",
  "microphone",
  "browser_audio_event",
  "tts_event",
  "speech_input_vad_adapter",
]);
const OBSERVATION_STATUSES = new Set([
  "observed",
  "held",
  "not_enabled",
  "not_available",
  "synthetic",
]);
const SPEECH_SOURCES = new Set([
  "none",
  "energy_heuristic",
  "webrtcvad_adapter",
  "speech_input_vad_adapter",
  "synthetic_fixture",
]);
const SOURCE_MODES = new Set([
  "source_static",
  "synthetic_fixture",
  "runtime_summary",
]);
const NO_LIVE_SOURCE_MODES = new Set(["source_static", "synthetic_fixture"]);
const PROOF_CEILINGS = new Set([
  SOURCE_STATIC_PROOF_CEILING,
  PC_OUTPUT_PROOF_CEILING,
  MICROPHONE_PROOF_CEILING,
  CORRELATION_PROOF_CEILING,
]);
const NON_CLAIMS = [
  "not_user_heard_audio",
  "not_browser_audio_playback",
  "not_microphone_content",
  "not_physical_device_effect",
  "not_raw_audio_publication",
  "not_full_transcript_publication",
  "not_home_assistant_action",
  "not_release_or_final_rr003",
];

function clamp(value, min, max) {
  if (!Number.isFinite(value)) return min;
  return Math.max(min, Math.min(max, value));
}

function round(value, digits = 2) {
  if (!Number.isFinite(value)) return null;
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

function dbfsFromAmplitude(amplitude) {
  if (!Number.isFinite(amplitude) || amplitude <= 0) return -160;
  return clamp(20 * Math.log10(Math.min(1, amplitude)), -160, 0);
}

function normalizeSamples(samples) {
  if (!Array.isArray(samples)) return [];
  return samples
    .map((sample) => Number(sample))
    .filter((sample) => Number.isFinite(sample))
    .map((sample) => clamp(sample, -1, 1));
}

function safeId(value, fallback) {
  const text = String(value ?? "").trim();
  return SAFE_ID_PATTERN.test(text) ? text : fallback;
}

function safeSummaryId(value, fallback) {
  const text = String(value ?? "").trim();
  return SUMMARY_ID_PATTERN.test(text) ? text : fallback;
}

function safeDate(value) {
  const text = String(value ?? "").trim();
  if (text && !Number.isNaN(Date.parse(text))) return text;
  return new Date().toISOString();
}

function safeRef(value) {
  const text = String(value ?? "").trim();
  return SAFE_REF_PATTERN.test(text) && !UNSAFE_REF_TEXT_PATTERN.test(text)
    ? text
    : null;
}

function defaultCapturePermissions({
  pcOutputCaptureEnabled = false,
  microphoneCaptureEnabled = false,
  microphonePermissionSource = microphoneCaptureEnabled
    ? "operator_granted"
    : "not_required",
  liveCaptureUsed = false,
} = {}) {
  return {
    pc_output_capture_enabled: Boolean(pcOutputCaptureEnabled),
    microphone_capture_enabled: Boolean(microphoneCaptureEnabled),
    microphone_permission_source: microphonePermissionSource,
    live_capture_used: Boolean(liveCaptureUsed),
    provider_network_stt_enabled: false,
    raw_audio_retained: false,
    raw_audio_persisted: false,
  };
}

export function analyzePcmWindow({
  channelId,
  channelKind,
  samples,
  sampleRate = 16000,
  windowMs = null,
  observationStatus = "synthetic",
  silenceThreshold = DEFAULT_SILENCE_THRESHOLD,
  audioPresentDbfs = DEFAULT_AUDIO_PRESENT_DBFS,
  speechPresent = null,
  speechPresenceSource = "energy_heuristic",
  sourceConfidence = null,
} = {}) {
  const normalized = normalizeSamples(samples);
  const sampleCount = normalized.length;
  const resolvedWindowMs =
    Number.isInteger(windowMs) && windowMs >= 0
      ? windowMs
      : sampleCount > 0 && sampleRate > 0
        ? Math.round((sampleCount / sampleRate) * 1000)
        : 0;
  const peak = sampleCount
    ? normalized.reduce((max, value) => Math.max(max, Math.abs(value)), 0)
    : 0;
  const rms = sampleCount
    ? Math.sqrt(
        normalized.reduce((sum, value) => sum + value * value, 0) /
          sampleCount,
      )
    : 0;
  const silenceCount = sampleCount
    ? normalized.filter((value) => Math.abs(value) <= silenceThreshold).length
    : 0;
  const rmsDbfs = dbfsFromAmplitude(rms);
  const peakDbfs = dbfsFromAmplitude(peak);
  const audioPresent = sampleCount > 0 && rmsDbfs > audioPresentDbfs;
  const clippingCount = sampleCount
    ? normalized.filter((value) => Math.abs(value) >= 0.99).length
    : 0;
  const confidence =
    sourceConfidence ?? (sampleCount > 0 ? (audioPresent ? 0.8 : 0.6) : null);

  return {
    channel_id: safeId(channelId, `${channelKind}.unknown`),
    channel_kind: CHANNEL_KINDS.has(channelKind) ? channelKind : "pc_output",
    observation_status: OBSERVATION_STATUSES.has(observationStatus)
      ? observationStatus
      : "held",
    window_ms: resolvedWindowMs,
    sample_count: sampleCount,
    rms_dbfs: sampleCount ? round(rmsDbfs) : null,
    peak_dbfs: sampleCount ? round(peakDbfs) : null,
    silence_ratio: sampleCount ? round(silenceCount / sampleCount, 4) : null,
    clipping_count: clippingCount,
    dropout_count: 0,
    audio_present: sampleCount ? audioPresent : null,
    speech_present: typeof speechPresent === "boolean" ? speechPresent : null,
    speech_presence_source: SPEECH_SOURCES.has(speechPresenceSource)
      ? speechPresenceSource
      : "none",
    source_confidence: Number.isFinite(confidence)
      ? round(clamp(confidence, 0, 1), 3)
      : null,
  };
}

export function buildDisabledChannel({
  channelId,
  channelKind,
  observationStatus = "not_enabled",
} = {}) {
  return {
    channel_id: safeId(channelId, `${channelKind}.not_enabled`),
    channel_kind: CHANNEL_KINDS.has(channelKind) ? channelKind : "microphone",
    observation_status: OBSERVATION_STATUSES.has(observationStatus)
      ? observationStatus
      : "not_enabled",
    window_ms: 0,
    sample_count: 0,
    rms_dbfs: null,
    peak_dbfs: null,
    silence_ratio: null,
    clipping_count: 0,
    dropout_count: 0,
    audio_present: null,
    speech_present: null,
    speech_presence_source: "none",
    source_confidence: null,
  };
}

export function buildSpeechInputVadAdapterChannel({
  channelId = "microphone.speech_input_vad_adapter",
  vad = {},
} = {}) {
  const checked = vad.checked === true;
  const speechDetected =
    typeof vad.speech_detected === "boolean" ? vad.speech_detected : null;
  return {
    channel_id: safeId(channelId, "microphone.speech_input_vad_adapter"),
    channel_kind: "speech_input_vad_adapter",
    observation_status: checked ? "observed" : "held",
    window_ms: 0,
    sample_count: 0,
    rms_dbfs: null,
    peak_dbfs: null,
    silence_ratio: null,
    clipping_count: 0,
    dropout_count: 0,
    audio_present: speechDetected,
    speech_present: speechDetected,
    speech_presence_source: checked ? "speech_input_vad_adapter" : "none",
    source_confidence: checked ? (speechDetected === true ? 0.72 : 0.64) : null,
  };
}

export function buildAudioAwarenessSummary({
  summaryId,
  generatedAt,
  routeId = null,
  proofCeiling = SOURCE_STATIC_PROOF_CEILING,
  sourceMode = "source_static",
  capturePermissions = {},
  channels = [],
  correlation = {},
  transcript = {},
} = {}) {
  const payload = {
    schema_version: SCHEMA_VERSION,
    summary_id: safeSummaryId(summaryId, "aud_sum_source_static_unknown"),
    generated_at: safeDate(generatedAt),
    proof_ceiling: PROOF_CEILINGS.has(proofCeiling)
      ? proofCeiling
      : SOURCE_STATIC_PROOF_CEILING,
    source_mode: SOURCE_MODES.has(sourceMode)
      ? sourceMode
      : "source_static",
    capture_permissions: {
      ...defaultCapturePermissions(),
      ...capturePermissions,
      provider_network_stt_enabled: false,
      raw_audio_retained: false,
      raw_audio_persisted: false,
    },
    channels,
    correlation: {
      self_output_event_ref: safeRef(correlation.self_output_event_ref),
      playback_event_ref: safeRef(correlation.playback_event_ref),
      pc_output_correlated:
        typeof correlation.pc_output_correlated === "boolean"
          ? correlation.pc_output_correlated
          : null,
      mic_input_correlated:
        typeof correlation.mic_input_correlated === "boolean"
          ? correlation.mic_input_correlated
          : null,
      estimated_lag_ms: Number.isInteger(correlation.estimated_lag_ms)
        ? clamp(correlation.estimated_lag_ms, 0, 10000)
        : null,
      speaker_bleed_likely:
        typeof correlation.speaker_bleed_likely === "boolean"
          ? correlation.speaker_bleed_likely
          : null,
      echo_likely:
        typeof correlation.echo_likely === "boolean"
          ? correlation.echo_likely
          : null,
      confidence: Number.isFinite(correlation.confidence)
        ? round(clamp(correlation.confidence, 0, 1), 3)
        : null,
    },
    transcript: {
      stt_attempted: Boolean(transcript.stt_attempted),
      transcript_present: Boolean(transcript.transcript_present),
      full_transcript_saved: false,
      raw_transcript_included: false,
      provider_payload_included: false,
      transcript_summary_ref: null,
    },
    redaction: {
      redaction_status: "summary_only",
      shareability_class:
        sourceMode === "runtime_summary"
          ? "runtime_audio_awareness_summary"
          : "source_static_audio_awareness_summary",
      raw_audio_shared: false,
      raw_audio_persisted: false,
      raw_transcript_shared: false,
      private_path_shared: false,
      private_endpoint_shared: false,
      home_assistant_identifier_shared: false,
      provider_payload_shared: false,
      screenshot_or_media_shared: false,
    },
    safety: {
      command_authority: false,
      action_authority: false,
      thought_core_completion_authority: false,
      home_assistant_action: false,
      browser_visible_audio_authority: false,
      user_heard_audio_authority: false,
      physical_device_proof_authority: false,
      provider_network_authority: false,
      release_or_final_rr003_authority: false,
    },
    non_claims: [...NON_CLAIMS],
  };
  if (routeId) payload.route_id = String(routeId);
  return payload;
}

export function buildSyntheticAudioAwarenessSummary({
  summaryId = "aud_sum_source_static_synthetic_self_test",
  generatedAt = "2026-06-22T00:00:00Z",
} = {}) {
  const sampleRate = 16000;
  const samples = Array.from({ length: sampleRate / 2 }, (_, index) => {
    const phase = (index / sampleRate) * 2 * Math.PI * 440;
    return 0.5 * Math.sin(phase);
  });
  return buildAudioAwarenessSummary({
    summaryId,
    generatedAt,
    routeId: "DEMO-AUDIO-AWARENESS-SOURCE-STATIC-01",
    proofCeiling: SOURCE_STATIC_PROOF_CEILING,
    sourceMode: "synthetic_fixture",
    capturePermissions: defaultCapturePermissions({
      microphonePermissionSource: "not_required",
    }),
    channels: [
      analyzePcmWindow({
        channelId: "pc_output.synthetic_tone",
        channelKind: "pc_output",
        samples,
        sampleRate,
        observationStatus: "synthetic",
        speechPresenceSource: "synthetic_fixture",
        sourceConfidence: 0.8,
      }),
      buildDisabledChannel({
        channelId: "microphone.not_enabled",
        channelKind: "microphone",
      }),
    ],
    correlation: {
      self_output_event_ref: null,
      playback_event_ref: null,
      pc_output_correlated: true,
      mic_input_correlated: null,
      estimated_lag_ms: 0,
      confidence: 0.7,
    },
  });
}

function assertConst(errors, value, expected, path) {
  if (value !== expected) errors.push(`${path} must be ${expected}`);
}

function assertFalse(errors, value, path) {
  if (value !== false) errors.push(`${path} must be false`);
}

function assertSafeRef(errors, value, path) {
  if (value === null || value === undefined) return;
  if (
    typeof value !== "string" ||
    !SAFE_REF_PATTERN.test(value) ||
    UNSAFE_REF_TEXT_PATTERN.test(value)
  ) {
    errors.push(`${path} must be a safe ref or null`);
  }
}

function assertNull(errors, value, path) {
  if (value !== null) errors.push(`${path} must be null`);
}

function assertChannel(errors, channel, index) {
  if (!channel || typeof channel !== "object" || Array.isArray(channel)) {
    errors.push(`channels[${index}] must be an object`);
    return;
  }
  if (!SAFE_ID_PATTERN.test(channel.channel_id)) {
    errors.push(`channels[${index}].channel_id is invalid`);
  }
  if (!CHANNEL_KINDS.has(channel.channel_kind)) {
    errors.push(`channels[${index}].channel_kind is invalid`);
  }
  if (!OBSERVATION_STATUSES.has(channel.observation_status)) {
    errors.push(`channels[${index}].observation_status is invalid`);
  }
  for (const field of ["window_ms", "sample_count", "clipping_count", "dropout_count"]) {
    if (!Number.isInteger(channel[field]) || channel[field] < 0) {
      errors.push(`channels[${index}].${field} must be a non-negative integer`);
    }
  }
  for (const field of ["rms_dbfs", "peak_dbfs", "silence_ratio", "source_confidence"]) {
    if (channel[field] !== null && !Number.isFinite(channel[field])) {
      errors.push(`channels[${index}].${field} must be a number or null`);
    }
  }
  if (!SPEECH_SOURCES.has(channel.speech_presence_source)) {
    errors.push(`channels[${index}].speech_presence_source is invalid`);
  }
}

export function validateAudioAwarenessSummary(payload) {
  const errors = [];
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return ["payload must be an object"];
  }
  assertConst(errors, payload.schema_version, SCHEMA_VERSION, "schema_version");
  if (!SUMMARY_ID_PATTERN.test(payload.summary_id)) {
    errors.push("summary_id is invalid");
  }
  if (
    typeof payload.generated_at !== "string" ||
    Number.isNaN(Date.parse(payload.generated_at))
  ) {
    errors.push("generated_at must be a date-time string");
  }
  if (!PROOF_CEILINGS.has(payload.proof_ceiling)) {
    errors.push("proof_ceiling is invalid");
  }
  if (!SOURCE_MODES.has(payload.source_mode)) {
    errors.push("source_mode is invalid");
  }
  if (!Array.isArray(payload.channels) || !payload.channels.length) {
    errors.push("channels must contain at least one channel");
  } else {
    payload.channels.forEach((channel, index) =>
      assertChannel(errors, channel, index),
    );
  }
  const permissions = payload.capture_permissions;
  if (!permissions || typeof permissions !== "object") {
    errors.push("capture_permissions is required");
  } else {
    assertFalse(
      errors,
      permissions.provider_network_stt_enabled,
      "capture_permissions.provider_network_stt_enabled",
    );
    assertFalse(
      errors,
      permissions.raw_audio_retained,
      "capture_permissions.raw_audio_retained",
    );
    assertFalse(
      errors,
      permissions.raw_audio_persisted,
      "capture_permissions.raw_audio_persisted",
    );
    if (NO_LIVE_SOURCE_MODES.has(payload.source_mode)) {
      assertFalse(
        errors,
        permissions.pc_output_capture_enabled,
        "capture_permissions.pc_output_capture_enabled",
      );
      assertFalse(
        errors,
        permissions.microphone_capture_enabled,
        "capture_permissions.microphone_capture_enabled",
      );
      assertFalse(
        errors,
        permissions.live_capture_used,
        "capture_permissions.live_capture_used",
      );
    }
  }
  const correlation = payload.correlation;
  if (!correlation || typeof correlation !== "object") {
    errors.push("correlation is required");
  } else {
    assertSafeRef(errors, correlation.self_output_event_ref, "correlation.self_output_event_ref");
    assertSafeRef(errors, correlation.playback_event_ref, "correlation.playback_event_ref");
  }
  const transcript = payload.transcript;
  if (!transcript || typeof transcript !== "object") {
    errors.push("transcript is required");
  } else {
    assertFalse(errors, transcript.full_transcript_saved, "transcript.full_transcript_saved");
    assertFalse(errors, transcript.raw_transcript_included, "transcript.raw_transcript_included");
    assertFalse(errors, transcript.provider_payload_included, "transcript.provider_payload_included");
    assertNull(errors, transcript.transcript_summary_ref, "transcript.transcript_summary_ref");
  }
  for (const sectionName of ["redaction", "safety"]) {
    if (!payload[sectionName] || typeof payload[sectionName] !== "object") {
      errors.push(`${sectionName} is required`);
    }
  }
  if (payload.redaction) {
    for (const field of [
      "raw_audio_shared",
      "raw_audio_persisted",
      "raw_transcript_shared",
      "private_path_shared",
      "private_endpoint_shared",
      "home_assistant_identifier_shared",
      "provider_payload_shared",
      "screenshot_or_media_shared",
    ]) {
      assertFalse(errors, payload.redaction[field], `redaction.${field}`);
    }
  }
  if (payload.safety) {
    for (const field of [
      "command_authority",
      "action_authority",
      "thought_core_completion_authority",
      "home_assistant_action",
      "browser_visible_audio_authority",
      "user_heard_audio_authority",
      "physical_device_proof_authority",
      "provider_network_authority",
      "release_or_final_rr003_authority",
    ]) {
      assertFalse(errors, payload.safety[field], `safety.${field}`);
    }
  }
  if (!Array.isArray(payload.non_claims)) {
    errors.push("non_claims must be an array");
  } else {
    for (const claim of NON_CLAIMS) {
      if (!payload.non_claims.includes(claim)) {
        errors.push(`non_claims missing ${claim}`);
      }
    }
  }
  return errors;
}

export const AUDIO_AWARENESS_SCHEMA_VERSION = SCHEMA_VERSION;
export const AUDIO_AWARENESS_NON_CLAIMS = NON_CLAIMS;
export const AUDIO_AWARENESS_SOURCE_STATIC_PROOF_CEILING =
  SOURCE_STATIC_PROOF_CEILING;
