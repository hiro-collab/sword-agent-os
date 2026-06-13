from pathlib import Path
import json
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from memory_core.classifier import classify_memory_issue_route


class MemoryCoreIssueClassifierTests(unittest.TestCase):
    def assertNoUnsafeEcho(self, result: dict) -> None:
        serialized = json.dumps(result, sort_keys=True)
        for fragment in (
            "synthetic-private",
            "synthetic-credential-marker",
            "provider_payload",
            "raw_frame",
            "light.synthetic_main",
            "sensor.synthetic_presence",
            "TRANSCRIPT_WORDS_SHOULD_NOT_APPEAR",
        ):
            self.assertNotIn(fragment, serialized)

    def test_raw_private_safety_stop_preempts_memory_and_issue(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-unsafe-1",
                "turn_id": "turn-classifier-unsafe-1",
                "event_id": "event-classifier-unsafe-1",
                "summary": "A safe-looking synthetic summary.",
                "tags": ["explicit_remember", "review_blocker"],
                "source_refs": ["trace:trace-classifier-unsafe-1"],
                "private_path_dynamic_hint": "X:\\synthetic-private\\memory.txt",
            }
        )

        self.assertEqual(result["route"], "needs_human_review")
        self.assertTrue(result["deterministic_safety_stop"])
        self.assertFalse(result["memory_write_allowed"])
        self.assertFalse(result["issue_candidate_allowed"])
        self.assertFalse(result["issue_publication_allowed"])
        self.assertFalse(result["llm_advisory_allowed"])
        self.assertIn("unsafe_input_detected", result["reason_codes"])
        self.assertNoUnsafeEcho(result)

    def test_current_state_missing_metadata_is_trace_only_or_human_review(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-state-1",
                "turn_id": "turn-classifier-state-1",
                "event_id": "event-classifier-state-1",
                "summary": "Synthetic current-state-like observation without enough metadata.",
                "tags": ["current_state", "explicit_remember"],
                "current_state_like": True,
                "source_refs": [],
            }
        )

        self.assertEqual(result["route"], "trace_only")
        self.assertIn("current_state_metadata_missing", result["reason_codes"])
        self.assertFalse(result["memory_write_allowed"])
        self.assertFalse(result["current_state_revalidated"])
        self.assertTrue(result["must_revalidate_current_state"])
        self.assertIn("current state truth", result["does_not_prove"])

    def test_resolved_issue_is_regression_context_not_current_failure(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-resolved-1",
                "turn_id": "turn-classifier-resolved-1",
                "event_id": "event-classifier-resolved-1",
                "summary": "Synthetic resolved issue context for future regression checks.",
                "tags": ["resolved_issue", "regression_reference"],
                "source_refs": ["trace:trace-classifier-resolved-1"],
                "resolved_issue_ref": "issue:RR003-SYNTHETIC-1",
            }
        )

        self.assertEqual(result["route"], "memory_candidate")
        self.assertTrue(result["memory_write_allowed"])
        self.assertFalse(result["issue_candidate_allowed"])
        self.assertFalse(result["issue_publication_allowed"])
        self.assertIn("resolved_issue", result["candidate_tags"])
        self.assertIn("regression_reference", result["candidate_tags"])
        self.assertIn("current failure", result["does_not_prove"])
        self.assertIn("fix still works", result["does_not_prove"])

    def test_same_failure_with_resolved_reference_can_route_both(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-both-1",
                "turn_id": "turn-classifier-both-1",
                "event_id": "event-classifier-both-1",
                "summary": "Synthetic fresh recurrence of a previously resolved failure.",
                "tags": ["resolved_issue", "regression_reference", "failure_pattern"],
                "source_refs": ["trace:trace-classifier-both-1"],
                "resolved_issue_ref": "issue:RR003-SYNTHETIC-2",
                "repeat_count": 2,
                "final_status": "failed",
            }
        )

        self.assertEqual(result["route"], "both")
        self.assertTrue(result["memory_write_allowed"])
        self.assertTrue(result["issue_candidate_allowed"])
        self.assertFalse(result["issue_publication_allowed"])
        self.assertIn("failure_pattern", result["issue_tags"])
        self.assertIn("resolved_reference_with_fresh_failure", result["reason_codes"])

    def test_retry_exhausted_internal_display_failure_routes_issue_candidate(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-retry-1",
                "turn_id": "turn-classifier-retry-1",
                "event_id": "event-classifier-retry-1",
                "summary": "Synthetic internal display retry limit was exhausted.",
                "tags": ["failure_pattern"],
                "source_refs": ["trace:trace-classifier-retry-1"],
                "side_effect_class": "self_display_internal",
                "action_kind": "expression_request",
                "retry_count": 2,
                "retry_limit": 2,
                "final_status": "failed",
            }
        )

        self.assertEqual(result["route"], "issue_candidate")
        self.assertFalse(result["memory_write_allowed"])
        self.assertTrue(result["issue_candidate_allowed"])
        self.assertFalse(result["issue_publication_allowed"])
        self.assertIn("retry_exhausted", result["issue_tags"])
        self.assertIn("failure_pattern", result["issue_tags"])
        self.assertFalse(result["safe_to_act"])

    def test_external_side_effect_needs_human_review(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-side-effect-1",
                "turn_id": "turn-classifier-side-effect-1",
                "event_id": "event-classifier-side-effect-1",
                "summary": "Synthetic Home Control side-effect summary.",
                "tags": ["failure_pattern", "review_blocker"],
                "source_refs": ["trace:trace-classifier-side-effect-1"],
                "side_effect_class": "home_control",
                "action_kind": "device_action",
                "retry_count": 2,
                "retry_limit": 2,
                "final_status": "failed",
            }
        )

        self.assertEqual(result["route"], "needs_human_review")
        self.assertTrue(result["deterministic_safety_stop"])
        self.assertIn("external_side_effect_requires_human_review", result["reason_codes"])
        self.assertFalse(result["memory_write_allowed"])
        self.assertFalse(result["issue_candidate_allowed"])
        self.assertFalse(result["issue_publication_allowed"])
        self.assertFalse(result["llm_advisory_allowed"])

    def test_explicit_remember_user_correction_routes_memory_candidate(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-memory-1",
                "turn_id": "turn-classifier-memory-1",
                "event_id": "event-classifier-memory-1",
                "summary": "Synthetic user correction useful for later turns.",
                "tags": ["explicit_remember", "user_correction"],
                "source_refs": ["trace:trace-classifier-memory-1"],
            }
        )

        self.assertEqual(result["route"], "memory_candidate")
        self.assertTrue(result["memory_write_allowed"])
        self.assertFalse(result["issue_candidate_allowed"])
        self.assertFalse(result["issue_publication_allowed"])
        self.assertIn("user_correction", result["candidate_tags"])
        self.assertFalse(result["durable_memory_claimed"])

    def test_safe_semantic_ambiguity_routes_llm_advisory_only(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-llm-1",
                "turn_id": "turn-classifier-llm-1",
                "event_id": "event-classifier-llm-1",
                "summary": "Synthetic safe ambiguity requires semantic classification.",
                "tags": ["semantic_ambiguous"],
                "source_refs": ["trace:trace-classifier-llm-1"],
                "llm_semantic_needed": True,
            }
        )

        self.assertEqual(result["route"], "needs_llm_classification")
        self.assertTrue(result["needs_llm_classification"])
        self.assertTrue(result["llm_advisory_allowed"])
        self.assertFalse(result["llm_final_authority"])
        self.assertFalse(result["memory_write_allowed"])
        self.assertFalse(result["issue_candidate_allowed"])
        self.assertFalse(result["provider_called"])

    def test_one_off_low_impact_routes_trace_only(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-one-off-1",
                "turn_id": "turn-classifier-one-off-1",
                "event_id": "event-classifier-one-off-1",
                "summary": "Synthetic low-impact one-off observation.",
                "tags": ["safe_summary"],
                "source_refs": ["trace:trace-classifier-one-off-1"],
            }
        )

        self.assertEqual(result["route"], "trace_only")
        self.assertFalse(result["memory_write_allowed"])
        self.assertFalse(result["issue_candidate_allowed"])
        self.assertFalse(result["issue_publication_allowed"])
        self.assertIn("trace_only_low_impact", result["reason_codes"])

    def test_unsafe_dynamic_keys_and_values_do_not_emit(self):
        result = classify_memory_issue_route(
            {
                "trace_id": "trace-classifier-dynamic-1",
                "turn_id": "turn-classifier-dynamic-1",
                "event_id": "event-classifier-dynamic-1",
                "summary": "TRANSCRIPT_WORDS_SHOULD_NOT_APPEAR",
                "tags": ["explicit_remember"],
                "source_refs": ["trace:trace-classifier-dynamic-1"],
                "artifact_raw_frame_ref": "raw_frame:synthetic-proof",
                "sensor.synthetic_presence": "active",
                "action": {
                    "target": "light.synthetic_main",
                    "provider_payload_hint": "provider_payload:synthetic",
                },
                "access_token_hint": "synthetic-credential-marker",
            }
        )

        self.assertEqual(result["route"], "needs_human_review")
        self.assertTrue(result["deterministic_safety_stop"])
        self.assertFalse(result["memory_write_allowed"])
        self.assertFalse(result["issue_publication_allowed"])
        self.assertIn("unsafe_key_or_ref", result["reason_codes"])
        self.assertNoUnsafeEcho(result)


if __name__ == "__main__":
    unittest.main()
