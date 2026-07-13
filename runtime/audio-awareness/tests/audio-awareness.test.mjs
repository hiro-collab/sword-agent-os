import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import {
  analyzePcmWindow,
  AUDIO_AWARENESS_NON_CLAIMS,
  AUDIO_AWARENESS_SCHEMA_VERSION,
  buildAudioAwarenessSummary,
  buildSpeechInputVadAdapterChannel,
  buildSyntheticAudioAwarenessSummary,
  selectSyntheticAecOwner,
  validateAudioAwarenessSummary,
} from "../audio-awareness.mjs";

const schema = JSON.parse(
  fs.readFileSync(
    new URL(
      "../../../contracts/audio_awareness_summary/audio_awareness_summary.v0.schema.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
const fixture = JSON.parse(
  fs.readFileSync(
    new URL(
      "../../../contracts/audio_awareness_summary/examples/pc-output-voicevox-correlated.example.json",
      import.meta.url,
    ),
    "utf8",
  ),
);

test("builds a summary-only synthetic PC-output packet", () => {
  const payload = buildSyntheticAudioAwarenessSummary();

  assert.equal(payload.schema_version, AUDIO_AWARENESS_SCHEMA_VERSION);
  assert.equal(payload.source_mode, "synthetic_fixture");
  assert.equal(payload.capture_permissions.live_capture_used, false);
  assert.equal(payload.capture_permissions.raw_audio_persisted, false);
  assert.equal(payload.channels[0].channel_kind, "pc_output");
  assert.equal(payload.channels[0].audio_present, true);
  assert.equal(payload.channels[1].channel_kind, "microphone");
  assert.equal(payload.channels[1].observation_status, "not_enabled");
  assert.equal(payload.correlation.self_output_event_ref, null);
  assert.equal(payload.correlation.playback_event_ref, null);
  assert.equal(payload.transcript.transcript_summary_ref, null);
  assert.equal(payload.redaction.raw_audio_shared, false);
  assert.equal(payload.safety.command_authority, false);
  assert.deepEqual(validateAudioAwarenessSummary(payload), []);
});

test("summarizes samples without retaining raw audio", () => {
  const channel = analyzePcmWindow({
    channelId: "microphone.synthetic_voice",
    channelKind: "microphone",
    samples: [0, 0.25, -0.25, 0.5, -0.5],
    sampleRate: 1000,
    observationStatus: "synthetic",
    speechPresent: true,
    speechPresenceSource: "synthetic_fixture",
  });

  assert.equal(channel.sample_count, 5);
  assert.equal(channel.audio_present, true);
  assert.equal(channel.speech_present, true);
  assert.equal(channel.raw_audio, undefined);
  assert.equal(channel.peak_dbfs, -6.02);
});

test("selects exactly one synthetic AEC owner with summary-only output", () => {
  const result = selectSyntheticAecOwner({
    processingInventoryClass: "known_no_owner",
    activeOwnerClasses: [],
    candidates: [
      {
        owner_class: "windows_voice_capture_dsp",
        echo_convergence_db: 20,
        near_end_preservation_ratio: 1,
        raw_audio: [0.1, 0.2],
      },
      {
        owner_class: "webrtc_apm_aec3",
        echo_convergence_db: 13.979,
        near_end_preservation_ratio: 1,
      },
    ],
  });

  assert.deepEqual(result, {
    schema_version: "synthetic_aec_owner_selection.v0",
    proof_ceiling: "synthetic_aec_owner_selection_only",
    result_class: "synthetic_aec_owner_selected",
    processing_inventory_class: "known_no_owner",
    candidate_count: 2,
    selected_owner_class: "windows_voice_capture_dsp",
    selected_echo_convergence_db: 20,
    selected_near_end_preservation_ratio: 1,
    exactly_one_aec_owner: true,
    observation_only: false,
    render_reference_may_create_turn_input: false,
    raw_audio_persisted: false,
    live_audio_used: false,
  });
  assert.equal(result.raw_audio, undefined);
  assert.equal(JSON.stringify(result).includes("0.1"), false);
});

test("AEC owner selection fails closed for unknown double and tied states", () => {
  const tiedCandidates = [
    {
      owner_class: "windows_voice_capture_dsp",
      echo_convergence_db: 12,
      near_end_preservation_ratio: 0.95,
    },
    {
      owner_class: "webrtc_apm_aec3",
      echo_convergence_db: 12,
      near_end_preservation_ratio: 0.95,
    },
  ];
  const cases = [
    ["unknown", [], "aec_processing_unknown_observation_only"],
    [
      "double_owner",
      ["windows_voice_capture_dsp", "webrtc_apm_aec3"],
      "aec_double_owner_rejected",
    ],
    ["known_no_owner", [], "synthetic_aec_owner_ambiguous"],
  ];
  for (const [
    processingInventoryClass,
    activeOwnerClasses,
    resultClass,
  ] of cases) {
    const result = selectSyntheticAecOwner({
      processingInventoryClass,
      activeOwnerClasses,
      candidates: tiedCandidates,
    });
    assert.equal(result.result_class, resultClass);
    assert.equal(result.selected_owner_class, null);
    assert.equal(result.exactly_one_aec_owner, false);
    assert.equal(result.observation_only, true);
    assert.equal(result.render_reference_may_create_turn_input, false);
  }
});

test("AEC owner selection does not echo invalid private candidates", () => {
  const privateMarker = String.raw`private C:\audio\device`;
  const result = selectSyntheticAecOwner({
    processingInventoryClass: "known_no_owner",
    activeOwnerClasses: [],
    candidates: [
      {
        owner_class: privateMarker,
        echo_convergence_db: 20,
        near_end_preservation_ratio: 1,
      },
    ],
  });

  assert.equal(
    result.result_class,
    "synthetic_aec_candidate_invalid_observation_only",
  );
  assert.equal(result.candidate_count, 1);
  assert.equal(result.selected_owner_class, null);
  assert.equal(JSON.stringify(result).includes(privateMarker), false);
});

test("AEC synthetic winner cannot replace a different active owner", () => {
  const result = selectSyntheticAecOwner({
    processingInventoryClass: "known_single_owner",
    activeOwnerClasses: ["webrtc_apm_aec3"],
    candidates: [
      {
        owner_class: "windows_voice_capture_dsp",
        echo_convergence_db: 18,
        near_end_preservation_ratio: 0.98,
      },
    ],
  });

  assert.equal(
    result.result_class,
    "aec_active_owner_mismatch_observation_only",
  );
  assert.equal(result.selected_owner_class, null);
  assert.equal(result.observation_only, true);
});

test("any malformed AEC candidate blocks selection from the valid subset", () => {
  const valid = {
    owner_class: "windows_voice_capture_dsp",
    echo_convergence_db: 20,
    near_end_preservation_ratio: 1,
  };
  const malformedCandidates = [
    {
      owner_class: "windows_voice_capture_dsp",
      echo_convergence_db: "private-same-owner-marker",
      near_end_preservation_ratio: 1,
    },
    {
      owner_class: "webrtc_apm_aec3",
      echo_convergence_db: 13.979,
      near_end_preservation_ratio: "private-other-owner-marker",
    },
  ];

  for (const malformed of malformedCandidates) {
    const result = selectSyntheticAecOwner({
      processingInventoryClass: "known_no_owner",
      candidates: [valid, malformed],
    });
    assert.equal(
      result.result_class,
      "synthetic_aec_candidate_invalid_observation_only",
    );
    assert.equal(result.candidate_count, 2);
    assert.equal(result.selected_owner_class, null);
    assert.equal(result.observation_only, true);
    assert.doesNotMatch(JSON.stringify(result), /private-.*-owner-marker/);
  }
});

test("duplicate summaries for one AEC owner remain ambiguous", () => {
  const result = selectSyntheticAecOwner({
    processingInventoryClass: "known_no_owner",
    candidates: [
      {
        owner_class: "windows_voice_capture_dsp",
        echo_convergence_db: 20,
        near_end_preservation_ratio: 1,
      },
      {
        owner_class: "windows_voice_capture_dsp",
        echo_convergence_db: 15,
        near_end_preservation_ratio: 0.95,
      },
    ],
  });

  assert.equal(result.result_class, "synthetic_aec_owner_ambiguous");
  assert.equal(result.selected_owner_class, null);
  assert.equal(result.observation_only, true);
});

test("high convergence cannot override weak near-end preservation", () => {
  const result = selectSyntheticAecOwner({
    processingInventoryClass: "known_no_owner",
    candidates: [
      {
        owner_class: "windows_voice_capture_dsp",
        echo_convergence_db: 30,
        near_end_preservation_ratio: 0.7,
      },
    ],
  });

  assert.equal(result.result_class, "synthetic_aec_candidate_unqualified");
  assert.equal(result.selected_owner_class, null);
  assert.equal(result.observation_only, true);
});

test("AEC selection thresholds have exact inclusive boundaries", () => {
  const candidate = (
    owner_class,
    echo_convergence_db,
    near_end_preservation_ratio,
  ) => ({
    owner_class,
    echo_convergence_db,
    near_end_preservation_ratio,
  });
  const singleCases = [
    [6, 1, "synthetic_aec_owner_selected"],
    [5.999, 1, "synthetic_aec_candidate_unqualified"],
    [30, 0.85, "synthetic_aec_owner_selected"],
    [30, 0.849, "synthetic_aec_candidate_unqualified"],
  ];
  for (const [convergence, preservation, resultClass] of singleCases) {
    const result = selectSyntheticAecOwner({
      processingInventoryClass: "known_no_owner",
      candidates: [
        candidate("windows_voice_capture_dsp", convergence, preservation),
      ],
    });
    assert.equal(result.result_class, resultClass);
  }

  const marginSelected = selectSyntheticAecOwner({
    processingInventoryClass: "known_no_owner",
    candidates: [
      candidate("windows_voice_capture_dsp", 10, 1),
      candidate("webrtc_apm_aec3", 9, 1),
    ],
  });
  assert.equal(marginSelected.result_class, "synthetic_aec_owner_selected");
  const marginAmbiguous = selectSyntheticAecOwner({
    processingInventoryClass: "known_no_owner",
    candidates: [
      candidate("windows_voice_capture_dsp", 10, 1),
      candidate("webrtc_apm_aec3", 9.001, 1),
    ],
  });
  assert.equal(marginAmbiguous.result_class, "synthetic_aec_owner_ambiguous");

  const halfStep = selectSyntheticAecOwner({
    processingInventoryClass: "known_no_owner",
    candidates: [candidate("windows_voice_capture_dsp", 6.2345, 0.9005)],
  });
  assert.deepEqual(halfStep, {
    schema_version: "synthetic_aec_owner_selection.v0",
    proof_ceiling: "synthetic_aec_owner_selection_only",
    result_class: "synthetic_aec_owner_selected",
    processing_inventory_class: "known_no_owner",
    candidate_count: 1,
    selected_owner_class: "windows_voice_capture_dsp",
    selected_echo_convergence_db: 6.235,
    selected_near_end_preservation_ratio: 0.901,
    exactly_one_aec_owner: true,
    observation_only: false,
    render_reference_may_create_turn_input: false,
    raw_audio_persisted: false,
    live_audio_used: false,
  });
});

test("maps speech-input VAD debug into hearing summary channel", () => {
  const channel = buildSpeechInputVadAdapterChannel({
    vad: {
      checked: true,
      speech_detected: true,
      reason: "speech_detected",
      aggressiveness: 2,
    },
  });

  assert.equal(channel.channel_kind, "speech_input_vad_adapter");
  assert.equal(channel.observation_status, "observed");
  assert.equal(channel.speech_present, true);
  assert.equal(channel.speech_presence_source, "speech_input_vad_adapter");
});

test("keeps committed fixture compatible with the runtime validator", () => {
  assert.deepEqual(validateAudioAwarenessSummary(fixture), []);
  assert.equal(fixture.correlation.self_output_event_ref, null);
  assert.equal(fixture.correlation.playback_event_ref, null);
  assert.equal(fixture.transcript.transcript_summary_ref, null);
  assert.equal(fixture.redaction.raw_audio_shared, false);
  assert.equal(fixture.transcript.full_transcript_saved, false);
  for (const claim of AUDIO_AWARENESS_NON_CLAIMS) {
    assert.ok(fixture.non_claims.includes(claim));
  }
});

test("normalizes legacy self-output refs away from summaries", () => {
  const payload = buildAudioAwarenessSummary({
    summaryId: "aud_sum_legacy_ref_normalized",
    generatedAt: "2026-06-22T00:00:00Z",
    channels: [
      analyzePcmWindow({
        channelId: "pc_output.synthetic_tone",
        channelKind: "pc_output",
        samples: [0.2, 0.2, 0.2],
      }),
    ],
    correlation: {
      self_output_event_ref: "tts:synthetic_source_static",
      playback_event_ref: "playback:synthetic_source_static",
    },
    transcript: {
      transcript_summary_ref: "summary:transcript_like_ref",
    },
  });

  assert.equal(payload.correlation.self_output_event_ref, null);
  assert.equal(payload.correlation.playback_event_ref, null);
  assert.equal(payload.transcript.transcript_summary_ref, null);
  assert.deepEqual(validateAudioAwarenessSummary(payload), []);
});

test("rejects legacy and transcript-like refs in received summaries", () => {
  const payload = buildAudioAwarenessSummary({
    summaryId: "aud_sum_bad_refs",
    generatedAt: "2026-06-22T00:00:00Z",
    channels: [
      analyzePcmWindow({
        channelId: "pc_output.synthetic_tone",
        channelKind: "pc_output",
        samples: [0.2, 0.2, 0.2],
      }),
    ],
  });

  const badRefs = [
    ["correlation.self_output_event_ref", "tts:local_voicevox_001"],
    ["correlation.playback_event_ref", "playback:local_player_001"],
    ["correlation.self_output_event_ref", "source:localStorage.audio_key"],
    ["correlation.playback_event_ref", "audio:voice.wav"],
    ["correlation.self_output_event_ref", "provider:voicevox_001"],
    ["transcript.transcript_summary_ref", "summary:transcript_like_ref"],
    ["transcript.transcript_summary_ref", "transcript body text"],
  ];

  for (const [path, ref] of badRefs) {
    const candidate = structuredClone(payload);
    if (path.startsWith("correlation.")) {
      candidate.correlation[path.split(".")[1]] = ref;
    } else {
      candidate.transcript.transcript_summary_ref = ref;
    }
    assert.notDeepEqual(validateAudioAwarenessSummary(candidate), [], path);
  }
});

test("rejects raw/private or authority upgrades", () => {
  const payload = buildAudioAwarenessSummary({
    summaryId: "aud_sum_bad_upgrade",
    generatedAt: "2026-06-22T00:00:00Z",
    channels: [
      analyzePcmWindow({
        channelId: "pc_output.synthetic_tone",
        channelKind: "pc_output",
        samples: [0.2, 0.2, 0.2],
      }),
    ],
  });
  payload.redaction.raw_audio_shared = true;
  payload.safety.user_heard_audio_authority = true;

  assert.match(
    validateAudioAwarenessSummary(payload).join("\n"),
    /raw_audio_shared must be false/,
  );
  assert.match(
    validateAudioAwarenessSummary(payload).join("\n"),
    /user_heard_audio_authority must be false/,
  );
});

test("rejects source/static live-capture upgrades", () => {
  const payload = buildAudioAwarenessSummary({
    summaryId: "aud_sum_bad_source_static_live_capture",
    generatedAt: "2026-06-22T00:00:00Z",
    sourceMode: "source_static",
    capturePermissions: {
      pc_output_capture_enabled: true,
      microphone_capture_enabled: true,
      live_capture_used: true,
    },
    channels: [
      analyzePcmWindow({
        channelId: "pc_output.synthetic_tone",
        channelKind: "pc_output",
        samples: [0.2, 0.2, 0.2],
      }),
    ],
  });

  assert.match(
    validateAudioAwarenessSummary(payload).join("\n"),
    /pc_output_capture_enabled must be false/,
  );
  assert.match(
    validateAudioAwarenessSummary(payload).join("\n"),
    /microphone_capture_enabled must be false/,
  );
  assert.match(
    validateAudioAwarenessSummary(payload).join("\n"),
    /live_capture_used must be false/,
  );
});

test("schema locks raw audio and transcript safety constants", () => {
  assert.equal(
    schema.properties.schema_version.const,
    AUDIO_AWARENESS_SCHEMA_VERSION,
  );
  assert.equal(
    schema.properties.capture_permissions.properties.raw_audio_persisted.const,
    false,
  );
  assert.equal(
    schema.properties.transcript.properties.full_transcript_saved.const,
    false,
  );
  assert.equal(
    schema.properties.transcript.properties.transcript_summary_ref.type,
    "null",
  );
  assert.doesNotMatch(schema.$defs.safe_ref.pattern, /\btts\b|\bplayback\b/);
  assert.equal(
    schema.properties.safety.properties.home_assistant_action.const,
    false,
  );
  assert.equal(
    schema.allOf[0].then.properties.capture_permissions.properties
      .pc_output_capture_enabled.const,
    false,
  );
  assert.equal(
    schema.allOf[0].then.properties.capture_permissions.properties
      .microphone_capture_enabled.const,
    false,
  );
  assert.equal(
    schema.allOf[0].then.properties.capture_permissions.properties
      .live_capture_used.const,
    false,
  );
});
