from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from memory_core.store import MemoryStore


class MemoryCoreRetrievalDepthTests(unittest.TestCase):
    def test_light_auto_without_scope_does_not_read_all_memory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-scope-1",
                        "trace_id": "trace-scope-1",
                        "turn_id": "turn-scope-1",
                        "summary": "A scoped memory should not be returned by an unscoped light query.",
                        "tags": ["work_continuity"],
                        "source_refs": ["trace:trace-scope-1"],
                    }
                )

                context = store.retrieve_context(
                    retrieval_depth="light_auto",
                    query_reason="ordinary_turn",
                )

                self.assertEqual(context["schema_version"], "memory_context_ref.v0")
                self.assertEqual(context["retrieval_depth"], "light_auto")
                self.assertEqual(context["result_count"], 0)
                self.assertEqual(context["result_ids"], [])
                self.assertFalse(context["broad_scan_performed"])
                self.assertFalse(context["safe_to_act"])
                self.assertFalse(context["durable_memory_claimed"])
                self.assertIn("not_all_memory_read", context["non_claims"])
            finally:
                store.close()

    def test_conditional_deep_returns_revalidation_marked_context_by_tag(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-context-state-1",
                        "trace_id": "trace-context-state-1",
                        "turn_id": "turn-context-state-1",
                        "summary": "A prior synthetic current-state observation needs revalidation.",
                        "tags": ["current_state", "review_blocker"],
                        "source_refs": ["trace:trace-context-state-1", "event:event-context-state-1"],
                        "state_value": "synthetic_state_observed",
                        "observed_at": "2026-06-12T00:00:00Z",
                        "fresh_until": "2026-06-12T00:05:00Z",
                        "source_author": "synthetic_environment_state",
                        "evidence_layer": "historical_observation",
                    }
                )

                context = store.retrieve_context(
                    retrieval_depth="conditional_deep",
                    query_reason="review_blocker_followup",
                    tags=["review_blocker"],
                )

                self.assertEqual(context["result_ids"], ["memcand-context-state-1"])
                self.assertIn("memcand-context-state-1", context["revalidation_required_record_ids"])
                self.assertFalse(context["current_state_revalidated"])
                self.assertIn("current state truth", context["does_not_prove"])
                result = context["results"][0]
                self.assertTrue(result["must_revalidate_current_state"])
                self.assertEqual(result["state_observation"]["state_semantic_class"], "historical_observation")
                serialized = json.dumps(context, sort_keys=True)
                self.assertNotIn("raw_prompt", serialized)
                self.assertNotIn("provider_payload", serialized)
                self.assertNotIn("entity_id", serialized)
            finally:
                store.close()

    def test_light_auto_is_bounded_and_keeps_resolved_issue_history_lower_priority(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-resolved-history-1",
                        "trace_id": "trace-resolved-history-1",
                        "turn_id": "turn-resolved-history-1",
                        "summary": "Resolved issue memory is regression context, not ordinary recall noise.",
                        "tags": ["work_continuity", "resolved_issue", "regression_reference"],
                        "source_refs": ["trace:trace-resolved-history-1"],
                        "issue_ref": "RR003-ISSUE-SYNTHETIC-RESOLVED",
                        "resolved_at": "2026-06-12T01:00:00Z",
                    }
                )
                for index in range(5):
                    store.record_candidate(
                        {
                            "memory_candidate_id": f"memcand-bounded-{index}",
                            "trace_id": f"trace-bounded-{index}",
                            "turn_id": f"turn-bounded-{index}",
                            "summary": f"Synthetic bounded memory {index}.",
                            "tags": ["work_continuity"],
                            "source_refs": [f"trace:trace-bounded-{index}"],
                        }
                    )

                light = store.retrieve_context(
                    retrieval_depth="light_auto",
                    query_reason="ordinary_turn",
                    tags=["work_continuity"],
                )
                self.assertEqual(light["max_results"], 3)
                self.assertEqual(light["result_count"], 3)
                self.assertNotIn("memcand-resolved-history-1", light["result_ids"])
                self.assertTrue(
                    any(
                        blocked["record_id"] == "memcand-resolved-history-1"
                        and blocked["reason_code"] == "low_priority_history_excluded"
                        for blocked in light["blocked_results"]
                    )
                )

                explicit = store.retrieve_context(
                    retrieval_depth="explicit_recall",
                    query_reason="regression_history_request",
                    tags=["regression_reference"],
                )
                self.assertIn("memcand-resolved-history-1", explicit["result_ids"])
            finally:
                store.close()

    def test_blocked_records_and_unsafe_query_values_do_not_leak_to_context(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-metadata-hold-1",
                        "trace_id": "trace-metadata-hold-1",
                        "turn_id": "turn-metadata-hold-1",
                        "summary": "A synthetic state-like record lacks source metadata.",
                        "tags": ["current_state"],
                        "state_value": "synthetic_state_observed",
                        "evidence_layer": "historical_observation",
                    }
                )

                context = store.retrieve_context(
                    retrieval_depth="explicit_recall",
                    query_reason="current_state_audit",
                    record_ids=["memcand-metadata-hold-1"],
                    tags=["X:\\synthetic-private\\not-a-real-path.txt", "light.synthetic_device"],
                    source_refs=["provider_payload:synthetic"],
                )
                self.assertEqual(context["result_ids"], [])
                self.assertTrue(
                    any(
                        blocked["record_id"] == "memcand-metadata-hold-1"
                        and blocked["reason_code"] == "normal_retrieval_not_allowed"
                        for blocked in context["blocked_results"]
                    )
                )
                self.assertEqual(context["record_ids_requested"], ["memcand-metadata-hold-1"])
                serialized = json.dumps(context, sort_keys=True)
                self.assertNotIn("synthetic-private", serialized)
                self.assertNotIn("light.synthetic_device", serialized)
                self.assertNotIn("provider_payload", serialized)
                self.assertIn("not_current_state_without_revalidation", context["non_claims"])
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
