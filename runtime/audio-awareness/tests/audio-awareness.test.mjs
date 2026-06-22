import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import {
  analyzePcmWindow,
  AUDIO_AWARENESS_NON_CLAIMS,
  AUDIO_AWARENESS_SCHEMA_VERSION,
  buildAudioAwarenessSummary,
  buildLegacyVadChannel,
  buildSyntheticAudioAwarenessSummary,
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

test("maps legacy speech-input VAD debug into hearing summary channel", () => {
  const channel = buildLegacyVadChannel({
    vad: {
      checked: true,
      speech_detected: true,
      reason: "speech_detected",
      aggressiveness: 2,
    },
  });

  assert.equal(channel.channel_kind, "legacy_speech_input");
  assert.equal(channel.observation_status, "observed");
  assert.equal(channel.speech_present, true);
  assert.equal(channel.speech_presence_source, "legacy_speech_input");
});

test("keeps committed fixture compatible with the runtime validator", () => {
  assert.deepEqual(validateAudioAwarenessSummary(fixture), []);
  assert.equal(fixture.redaction.raw_audio_shared, false);
  assert.equal(fixture.transcript.full_transcript_saved, false);
  for (const claim of AUDIO_AWARENESS_NON_CLAIMS) {
    assert.ok(fixture.non_claims.includes(claim));
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
