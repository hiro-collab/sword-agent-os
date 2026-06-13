from __future__ import annotations

import copy
import json
import re
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "contracts/redacted_turn_input/redacted_turn_input.v0.schema.json"
EXAMPLE = ROOT / "contracts/redacted_turn_input/examples/source_no_live.example.json"

FALSE_ONLY_FLAGS = {
    "raw_transcript_included",
    "raw_audio_included",
    "raw_media_included",
    "prompt_text_included",
    "response_text_included",
    "provider_payload_included",
    "private_path_included",
    "private_endpoint_included",
    "secret_or_token_included",
    "home_control_device_detail_included",
    "input_gate_only_is_stt_proof",
    "stt_only_is_thought_core_completion_proof",
    "action_execution_claimed",
    "motion_proof_claimed",
    "ordinary_conversation_quality_claimed",
    "robust_gesture_green_claimed",
    "source_adoption_or_git_claimed",
    "rr003_representative_pass_claimed",
}

SAFE_METADATA_KEYS = {
    "source_modality",
    "transcript_present",
    "transcript_bucket",
    "handoff_source",
    "handoff_field",
    "handoff_ref",
    "completion_seen",
    "completion_event_ref",
    "evidence_refs",
    "redaction_profile",
    "shareability_class",
    "does_not_prove",
}

FORBIDDEN_KEY_RE = re.compile(
    r"(^|_)(transcript|prompt|response|audio|media|path|endpoint|payload|secret|token|device|entity|service)($|_)",
    re.IGNORECASE,
)

FORBIDDEN_VALUE_PATTERNS = (
    re.compile(r"[A-Za-z]:[\\/]", re.IGNORECASE),
    re.compile(r"\\\\[A-Za-z0-9_.-]+\\"),
    re.compile(r"https?://", re.IGNORECASE),
    re.compile(r"\b(secret|token|provider_payload)\b", re.IGNORECASE),
    re.compile(r"\.(mp3|mp4|wav|m4a|webm|png|jpg|jpeg)\b", re.IGNORECASE),
    re.compile(r"\b(entity_id|service_call|home_assistant)\b", re.IGNORECASE),
)

REQUIRED_NON_CLAIMS = {
    "not_live_camera_audio",
    "not_browser_runtime",
    "not_vb_cable_or_sample_audio_stt",
    "not_action_execution",
    "not_home_control_state",
    "not_motion_proof",
    "not_ordinary_conversation_quality",
    "not_robust_gesture_gate_green",
    "not_source_adoption_or_git",
    "not_rr003_representative_pass",
}


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def walk(value: Any) -> list[Any]:
    values = [value]
    if isinstance(value, dict):
        for child in value.values():
            values.extend(walk(child))
    elif isinstance(value, list):
        for child in value:
            values.extend(walk(child))
    return values


def assert_summary_safe(payload: dict[str, Any]) -> None:
    def check(value: Any, path: tuple[str, ...] = ()) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                if key in FALSE_ONLY_FLAGS:
                    if child is not False:
                        raise AssertionError(f"{'.'.join(path + (key,))} must be false")
                elif key not in SAFE_METADATA_KEYS and FORBIDDEN_KEY_RE.search(key):
                    raise AssertionError(f"unsafe non-flag key: {'.'.join(path + (key,))}")
                check(child, path + (key,))
            return
        if isinstance(value, list):
            for index, child in enumerate(value):
                check(child, path + (str(index),))
            return
        if isinstance(value, str):
            for pattern in FORBIDDEN_VALUE_PATTERNS:
                if pattern.search(value):
                    raise AssertionError(f"unsafe value at {'.'.join(path)}")

    check(payload)


def assert_contract_shape(payload: dict[str, Any]) -> None:
    if payload["schema_version"] != "redacted_turn_input.v0":
        raise AssertionError("schema_version mismatch")
    if payload["proof_layer"] not in {"source-static", "source-no-live"}:
        raise AssertionError("unsupported proof_layer")
    if payload["input_gate_state"]["input_enabled"] is True and payload["stt"]["final_result"] is False:
        raise AssertionError("gate open alone cannot be a completed STT proof")
    if payload["stt"]["final_result"] is True and payload["thought_core"]["completion_seen"] is False:
        raise AssertionError("STT final alone cannot be a Thought Core completion proof")
    missing = REQUIRED_NON_CLAIMS - set(payload["does_not_prove"])
    if missing:
        raise AssertionError(f"missing non-claims: {sorted(missing)}")
    assert_summary_safe(payload)


class RedactedTurnInputContractTests(unittest.TestCase):
    def test_schema_and_example_parse(self) -> None:
        schema = load_json(SCHEMA)
        example = load_json(EXAMPLE)

        self.assertEqual(schema["properties"]["schema_version"]["const"], "redacted_turn_input.v0")
        self.assertEqual(example["schema_version"], "redacted_turn_input.v0")
        self.assertEqual(example["proof_layer"], "source-no-live")

    def test_source_no_live_example_keeps_only_redacted_metadata(self) -> None:
        example = load_json(EXAMPLE)

        assert_contract_shape(example)
        self.assertTrue(example["stt"]["transcript_present"])
        self.assertTrue(example["stt"]["final_result"])
        self.assertTrue(example["thought_core"]["completion_seen"])
        for flag in FALSE_ONLY_FLAGS:
            flag_values = [
                value[flag]
                for value in walk(example)
                if isinstance(value, dict) and flag in value
            ]
            self.assertTrue(flag_values, flag)
            self.assertTrue(all(item is False for item in flag_values), flag)

    def test_raw_transcript_audio_provider_and_private_path_fixtures_are_rejected(self) -> None:
        base = load_json(EXAMPLE)
        unsafe_cases = [
            ("raw transcript", ("stt", "transcript_text"), "blocked_source_value_001"),
            ("raw audio path", ("stt", "audio_path"), "blocked_source_value_audio_ref"),
            ("provider payload", ("stt", "provider_payload"), {"raw": "blocked_source_value_002"}),
            ("secret token", ("redaction", "secret_or_token_included"), True),
            ("device detail", ("handoff", "device_detail"), "blocked_source_value_003"),
        ]

        for label, path, value in unsafe_cases:
            with self.subTest(label=label):
                payload = copy.deepcopy(base)
                target = payload
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(AssertionError):
                    assert_contract_shape(payload)

    def test_gate_stt_and_thought_core_completion_are_separate_proof_steps(self) -> None:
        base = load_json(EXAMPLE)

        gate_without_stt = copy.deepcopy(base)
        gate_without_stt["stt"]["final_result"] = False
        with self.assertRaisesRegex(AssertionError, "gate open alone"):
            assert_contract_shape(gate_without_stt)

        stt_without_turn_completion = copy.deepcopy(base)
        stt_without_turn_completion["thought_core"]["completion_seen"] = False
        with self.assertRaisesRegex(AssertionError, "STT final alone"):
            assert_contract_shape(stt_without_turn_completion)


if __name__ == "__main__":
    unittest.main()
