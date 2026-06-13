from __future__ import annotations

import copy
import json
import re
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "contracts/gesture_gate_summary/gesture_gate_summary.v0.schema.json"
EXAMPLE = ROOT / "contracts/gesture_gate_summary/examples/source_no_live_cases.example.json"

FALSE_ONLY_FLAGS = {
    "raw_video_included",
    "raw_frame_included",
    "raw_audio_included",
    "raw_transcript_included",
    "raw_media_path_included",
    "private_path_included",
    "provider_payload_included",
    "secret_or_token_included",
    "device_detail_included",
    "gesture_gate_only_is_stt_proof",
    "gesture_gate_only_is_thought_core_proof",
    "gesture_gate_only_is_response_quality_proof",
    "action_execution_claimed",
    "home_control_state_claimed",
    "motion_or_expression_proof_claimed",
    "robust_gesture_green_claimed",
    "source_adoption_or_git_claimed",
    "rr003_representative_pass_claimed",
}

SAFE_METADATA_KEYS = {
    "proof_layer",
    "input_mode",
    "cases",
    "case_id",
    "fixture_label",
    "gesture_label",
    "expected_gate",
    "observed_gate",
    "accepted_activation_candidate",
    "proof_scope",
    "result",
    "known_limitations",
    "evidence_refs",
    "aggregate",
    "sword_open_pass",
    "victory_closed_pass",
    "open_hand_closed_pass",
    "victory_false_open_remaining",
    "gate_summary_result",
    "redaction_profile",
    "shareability_class",
    "does_not_prove",
}

FORBIDDEN_KEY_RE = re.compile(
    r"(^|_)(video|frame|audio|transcript|media|path|endpoint|payload|secret|token|device|entity|service|action|motion|expression|response)($|_)",
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
    "not_raw_media_publication",
    "not_browser_runtime",
    "not_stt_or_handoff_proof",
    "not_thought_core_turn_proof",
    "not_response_quality",
    "not_action_execution",
    "not_home_control_state",
    "not_motion_or_expression_proof",
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


def case_by_label(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {case["gesture_label"]: case for case in payload["cases"]}


def assert_contract_shape(payload: dict[str, Any]) -> None:
    if payload["schema_version"] != "gesture_gate_summary.v0":
        raise AssertionError("schema_version mismatch")
    if payload["proof_layer"] not in {"source-static", "source-no-live"}:
        raise AssertionError("unsupported proof_layer")
    missing = REQUIRED_NON_CLAIMS - set(payload["does_not_prove"])
    if missing:
        raise AssertionError(f"missing non-claims: {sorted(missing)}")
    if payload["aggregate"]["robust_gesture_gate_green"] is not False:
        raise AssertionError("robust gesture gate green must remain false in this contract slice")
    assert_summary_safe(payload)


class GestureGateSummaryContractTests(unittest.TestCase):
    def test_schema_and_example_parse(self) -> None:
        schema = load_json(SCHEMA)
        example = load_json(EXAMPLE)

        self.assertEqual(schema["properties"]["schema_version"]["const"], "gesture_gate_summary.v0")
        self.assertEqual(example["schema_version"], "gesture_gate_summary.v0")
        self.assertEqual(example["proof_layer"], "source-no-live")

    def test_three_case_source_no_live_summary_preserves_known_limitation(self) -> None:
        example = load_json(EXAMPLE)
        assert_contract_shape(example)

        cases = case_by_label(example)
        self.assertEqual(set(cases), {"sword_sign", "victory", "open_hand"})

        self.assertEqual(cases["sword_sign"]["expected_gate"], "open")
        self.assertEqual(cases["sword_sign"]["observed_gate"], "open")
        self.assertTrue(cases["sword_sign"]["accepted_activation_candidate"])
        self.assertEqual(cases["sword_sign"]["result"], "pass")

        self.assertEqual(cases["victory"]["expected_gate"], "closed")
        self.assertEqual(cases["victory"]["observed_gate"], "open")
        self.assertTrue(cases["victory"]["accepted_activation_candidate"])
        self.assertEqual(cases["victory"]["result"], "known_limitation_fail")
        self.assertIn("victory_false_open", cases["victory"]["known_limitations"])

        self.assertEqual(cases["open_hand"]["expected_gate"], "closed")
        self.assertEqual(cases["open_hand"]["observed_gate"], "closed")
        self.assertFalse(cases["open_hand"]["accepted_activation_candidate"])
        self.assertEqual(cases["open_hand"]["result"], "pass")

        self.assertFalse(example["aggregate"]["victory_closed_pass"])
        self.assertTrue(example["aggregate"]["victory_false_open_remaining"])
        self.assertFalse(example["aggregate"]["robust_gesture_gate_green"])

    def test_redaction_flags_are_false_and_raw_artifact_fixtures_are_rejected(self) -> None:
        base = load_json(EXAMPLE)
        assert_contract_shape(base)

        for flag in FALSE_ONLY_FLAGS:
            flag_values = [
                value[flag]
                for value in walk(base)
                if isinstance(value, dict) and flag in value
            ]
            self.assertTrue(flag_values, flag)
            self.assertTrue(all(item is False for item in flag_values), flag)

        unsafe_cases = [
            ("raw frame key", ("cases", 0, "raw_frame_ref"), "blocked_source_value_frame"),
            ("raw media path key", ("cases", 0, "raw_media_path"), "blocked_source_value_media"),
            ("provider payload key", ("cases", 0, "provider_payload"), {"raw": "blocked_source_value_payload"}),
            ("device detail flag", ("cases", 0, "redaction", "device_detail_included"), True),
            ("action claim flag", ("safety", "action_execution_claimed"), True),
        ]

        for label, path, value in unsafe_cases:
            with self.subTest(label=label):
                payload = copy.deepcopy(base)
                target: Any = payload
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(AssertionError):
                    assert_contract_shape(payload)

    def test_gate_summary_does_not_claim_downstream_layers(self) -> None:
        example = load_json(EXAMPLE)
        assert_contract_shape(example)

        safety = example["safety"]
        self.assertFalse(safety["gesture_gate_only_is_stt_proof"])
        self.assertFalse(safety["gesture_gate_only_is_thought_core_proof"])
        self.assertFalse(safety["gesture_gate_only_is_response_quality_proof"])
        self.assertFalse(safety["motion_or_expression_proof_claimed"])
        self.assertFalse(safety["source_adoption_or_git_claimed"])

        for non_claim in REQUIRED_NON_CLAIMS:
            self.assertIn(non_claim, example["does_not_prove"])


if __name__ == "__main__":
    unittest.main()
