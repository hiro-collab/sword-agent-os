from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from memory_core.store import MemoryStore


class MemoryCorePriorityPromotionTests(unittest.TestCase):
    def test_priority_ingest_tags_do_not_become_current_truth(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                summary = store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-priority-1",
                        "trace_id": "trace-priority-1",
                        "turn_id": "turn-priority-1",
                        "summary": "User explicitly asked that this review blocker be remembered.",
                        "tags": ["explicit_remember", "review_blocker", "long_term_candidate"],
                        "source_refs": ["trace:trace-priority-1", "event:event-priority-1"],
                        "memory_granularity": "decision_level",
                    }
                )
                self.assertEqual(summary["ingest_priority"], "priority")
                self.assertEqual(summary["priority_policy_id"], "memory_core_priority_ingest.v0")
                self.assertIn("tag:explicit_remember", summary["priority_reasons"])
                self.assertEqual(summary["importance"], "high")
                self.assertTrue(summary["long_term"])
                self.assertEqual(summary["memory_tier"], "long_term")
                self.assertEqual(summary["long_term_kind"], "decision_level")
                self.assertEqual(summary["retention_class"], "long_term_candidate")
                self.assertIn("explicit_remember", summary["priority_tags"])
                self.assertFalse(summary["durable_memory_claimed"])
                self.assertIn("current state", " ".join(summary["does_not_prove"]))
            finally:
                store.close()

    def test_current_state_candidate_is_historical_observation_and_revalidation_required(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                summary = store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-state-1",
                        "trace_id": "trace-state-1",
                        "turn_id": "turn-state-1",
                        "summary": "A synthetic status estimate was observed during a prior turn.",
                        "tags": ["current_state", "safety"],
                        "source_refs": ["trace:trace-state-1", "event:event-state-1"],
                        "state_value": "synthetic_state_observed",
                        "observed_at": "2026-06-12T00:00:00Z",
                        "fresh_until": "2026-06-12T00:05:00Z",
                        "source_author": "synthetic_environment_state",
                        "evidence_layer": "historical_observation",
                        "must_revalidate_current_state": False,
                    }
                )
                self.assertTrue(summary["must_revalidate_current_state"])
                self.assertEqual(summary["state_observation"]["state_semantic_class"], "historical_observation")
                self.assertEqual(summary["state_observation"]["evidence_layer"], "historical_observation")
                self.assertEqual(summary["state_observation"]["observed_at"], "2026-06-12T00:00:00Z")
            finally:
                store.close()

    def test_current_state_missing_observed_or_source_metadata_is_not_normally_retrievable(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                summary = store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-state-missing-meta-1",
                        "trace_id": "trace-state-missing-meta-1",
                        "turn_id": "turn-state-missing-meta-1",
                        "summary": "A synthetic current-state-like record lacks observation metadata.",
                        "tags": ["current_state"],
                        "state_value": "synthetic_state_observed",
                        "evidence_layer": "historical_observation",
                    }
                )
                self.assertEqual(summary["status"], "candidate_metadata_hold")
                self.assertTrue(summary["must_revalidate_current_state"])
                self.assertFalse(summary["normal_retrieval_allowed"])
                self.assertTrue(summary["history_retrieval_allowed"])
                self.assertFalse(summary["state_observation"]["metadata_complete_for_normal_retrieval"])
                self.assertEqual(
                    summary["state_observation"]["retrieval_block_reason"],
                    "missing_observed_or_source_metadata",
                )
                self.assertEqual(store.find_by_trace_id("trace-state-missing-meta-1"), [])
                by_id = store.get_summary("memcand-state-missing-meta-1")
                self.assertTrue(by_id["must_revalidate_current_state"])
            finally:
                store.close()

    def test_promotion_decision_records_policy_and_rejects_llm_final_authority(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-promote-1",
                        "trace_id": "trace-promote-1",
                        "turn_id": "turn-promote-1",
                        "summary": "A repeated correction should be considered for future recall.",
                        "tags": ["user_correction", "explicit_remember"],
                        "source_refs": ["trace:trace-promote-1"],
                    }
                )
                with self.assertRaises(ValueError):
                    store.record_promotion_decision(
                        "memcand-promote-1",
                        decision="promote",
                        reasons=["llm_only"],
                        evidence_refs=["trace:trace-promote-1"],
                        confidence=0.8,
                        llm_final_authority=True,
                    )
                decision = store.record_promotion_decision(
                    "memcand-promote-1",
                    decision="promote",
                    reasons=["explicit_remember", "source_ref_present"],
                    evidence_refs=["trace:trace-promote-1"],
                    confidence=0.8,
                    decided_by="memory_core_policy",
                )
                self.assertEqual(decision["decision"], "promote")
                self.assertEqual(decision["candidate_id"], "memcand-promote-1")
                self.assertIn("explicit_remember", decision["matched_criteria"])
                self.assertFalse(decision["llm_final_authority"])
                self.assertIn("durable production memory", decision["does_not_prove"])
                updated = store.get_summary("memcand-promote-1")
                self.assertEqual(updated["status"], "promotion_promote_recorded")
                self.assertFalse(updated["durable_memory_claimed"])
            finally:
                store.close()

    def test_promotion_decision_records_all_source_no_live_outcomes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                outcomes = ("hold", "reject", "quarantine", "superseded", "needs_human_review", "merge")
                for outcome in outcomes:
                    record_id = f"memcand-{outcome}-1"
                    store.record_candidate(
                        {
                            "memory_candidate_id": record_id,
                            "trace_id": f"trace-{outcome}-1",
                            "turn_id": f"turn-{outcome}-1",
                            "summary": f"Synthetic {outcome} decision candidate.",
                            "tags": ["user_correction"],
                            "source_refs": [f"trace:trace-{outcome}-1"],
                        }
                    )
                    decision = store.record_promotion_decision(
                        record_id,
                        decision=outcome,
                        reasons=[f"{outcome}_criterion"],
                        evidence_refs=[f"trace:trace-{outcome}-1"],
                        confidence=0.4,
                    )
                    self.assertEqual(decision["decision"], outcome)
                    self.assertFalse(decision["llm_final_authority"])
                    self.assertIn("issue-ticket closure", decision["does_not_prove"])
                    summary = store.get_summary(record_id)
                    if outcome in {"reject", "quarantine", "superseded"}:
                        self.assertFalse(summary["normal_retrieval_allowed"])
            finally:
                store.close()

    def test_unsafe_or_deletion_requested_records_are_not_promoted_or_normally_retrieved(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                unsafe = store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-unsafe-1",
                        "trace_id": "trace-unsafe-1",
                        "turn_id": "turn-unsafe-1",
                        "summary": "Unsafe synthetic fixture should be quarantined.",
                        "tags": ["explicit_remember"],
                        "source_refs": ["trace:trace-unsafe-1"],
                        "private_path_dynamic_hint": "X:\\synthetic-private\\memory.txt",
                    }
                )
                self.assertEqual(unsafe["status"], "candidate_quarantined")
                self.assertEqual(store.find_by_trace_id("trace-unsafe-1"), [])
                with self.assertRaises(ValueError):
                    store.record_promotion_decision(
                        "memcand-unsafe-1",
                        decision="promote",
                        reasons=["explicit_remember"],
                        evidence_refs=["trace:trace-unsafe-1"],
                    )

                deletion = store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-delete-1",
                        "trace_id": "trace-delete-1",
                        "turn_id": "turn-delete-1",
                        "summary": "Long-term candidate with a separate deletion request.",
                        "tags": ["long_term_candidate", "deletion_request"],
                        "source_refs": ["trace:trace-delete-1"],
                        "reference_count": 3,
                        "reinforcement_events": ["explicit_importance", "work_continuity"],
                    }
                )
                self.assertTrue(deletion["long_term"])
                self.assertTrue(deletion["deletion_requested"])
                self.assertEqual(deletion["memory_tier"], "long_term")
                self.assertEqual(deletion["reinforcement"]["reference_count"], 3)
                self.assertFalse(deletion["reinforcement"]["source_type_increases_confidence"])
                self.assertIn("explicit_importance", deletion["reinforcement"]["reinforcement_events"])
                self.assertFalse(deletion["normal_retrieval_allowed"])
                self.assertEqual(store.find_by_trace_id("trace-delete-1"), [])
            finally:
                store.close()

    def test_relation_supersession_fields_do_not_trigger_full_consolidation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                summary = store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-relation-1",
                        "trace_id": "trace-relation-1",
                        "turn_id": "turn-relation-1",
                        "summary": "A correction supersedes an older synthetic memory.",
                        "tags": ["user_correction"],
                        "source_refs": ["trace:trace-relation-1"],
                        "related_memory_ids": ["memcand-related-1"],
                        "same_topic_tags": ["review_flow"],
                        "supersedes": ["memcand-older-1"],
                        "superseded_by": ["memcand-newer-1"],
                        "derived_from_episode_id": "episode-synthetic-1",
                    }
                )
                self.assertTrue(summary["relation_metadata"]["merge_like_is_relation_only"])
                self.assertIn("memcand-older-1", summary["relation_metadata"]["supersedes"])
                relation_types = {row["relation_type"] for row in store.get_relations("memcand-relation-1")}
                self.assertIn("related_memory", relation_types)
                self.assertIn("same_topic_tag", relation_types)
                self.assertIn("supersedes", relation_types)
                self.assertIn("superseded_by", relation_types)
                self.assertIn("derived_from_episode", relation_types)
            finally:
                store.close()

    def test_resolved_issue_memory_is_history_context_not_current_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                summary = store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-resolved-1",
                        "trace_id": "trace-resolved-1",
                        "turn_id": "turn-resolved-1",
                        "summary": "A resolved issue should be retained for regression reference.",
                        "tags": ["resolved", "resolved_issue", "regression_reference"],
                        "source_refs": ["trace:trace-resolved-1"],
                        "issue_ref": "RR003-ISSUE-SYNTHETIC-RESOLVED",
                        "resolved_at": "2026-06-12T01:00:00Z",
                        "resolution_ref": "review:synthetic-resolution",
                        "resolved_by": "test_qa",
                        "regression_risk": "medium",
                    }
                )
                self.assertEqual(summary["importance"], "low")
                self.assertIn("resolved_issue", summary["tags"])
                self.assertEqual(summary["resolved_issue"]["issue_ref"], "RR003-ISSUE-SYNTHETIC-RESOLVED")
                self.assertTrue(summary["resolved_issue"]["does_not_prove_current_failure"])
                self.assertTrue(summary["resolved_issue"]["does_not_prove_fix_still_works"])
            finally:
                store.close()

    def test_lifecycle_actions_distinguish_normal_and_history_retrieval(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                for action in ("expire", "deprecate", "forget"):
                    record_id = f"memcand-{action}-lifecycle-1"
                    trace_id = f"trace-{action}-lifecycle-1"
                    store.record_candidate(
                        {
                            "memory_candidate_id": record_id,
                            "trace_id": trace_id,
                            "turn_id": f"turn-{action}-lifecycle-1",
                            "summary": f"Synthetic lifecycle {action} candidate.",
                            "tags": ["explicit_remember"],
                            "source_refs": [f"trace:{trace_id}"],
                        }
                    )
                    updated = store.record_lifecycle_event(
                        record_id,
                        lifecycle_action=action,
                        reason=f"synthetic {action} policy",
                    )
                    self.assertEqual(updated["lifecycle_action"], action)
                    self.assertFalse(updated["normal_retrieval_allowed"])
                    self.assertTrue(updated["history_retrieval_allowed"])
                    self.assertEqual(store.find_by_trace_id(trace_id), [])
            finally:
                store.close()

    def test_tombstone_blocks_normal_retrieval_and_keeps_reader_safe_audit_summary(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-tombstone-1",
                        "trace_id": "trace-tombstone-1",
                        "turn_id": "turn-tombstone-1",
                        "summary": "A memory that will receive a synthetic delete request.",
                        "tags": ["explicit_remember"],
                        "source_refs": ["trace:trace-tombstone-1", "event:event-tombstone-1"],
                    }
                )
                tombstone = store.tombstone_memory(
                    "memcand-tombstone-1",
                    reason="synthetic user deletion request",
                    requested_by="synthetic_user",
                    decided_by="memory_core_policy",
                )
                serialized = json.dumps(tombstone, sort_keys=True)
                self.assertEqual(tombstone["status"], "deleted_tombstoned")
                self.assertEqual(tombstone["lifecycle_action"], "delete")
                self.assertFalse(tombstone["normal_retrieval_allowed"])
                self.assertFalse(tombstone["history_retrieval_allowed"])
                self.assertEqual(store.find_by_trace_id("trace-tombstone-1"), [])
                self.assertIn("tombstone:", serialized)
                self.assertNotIn("raw_prompt", serialized)
                self.assertNotIn("provider_payload", serialized)
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
