from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from memory_core.store import MemoryStore


class MemoryCoreReinforcementUpdateTests(unittest.TestCase):
    def test_reference_and_successful_use_reinforce_reader_safe_summary(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-reinforce-1",
                        "trace_id": "trace-reinforce-1",
                        "turn_id": "turn-reinforce-1",
                        "summary": "A synthetic work-continuity memory can be reinforced.",
                        "tags": ["safe_summary"],
                        "source_refs": ["trace:trace-reinforce-1"],
                    }
                )

                reference = store.record_reinforcement_update(
                    "memcand-reinforce-1",
                    signal="reference",
                    reason="used for a later safe summary",
                    evidence_refs=["trace:trace-reinforce-1"],
                    source_type="manager_review",
                )
                self.assertEqual(reference["signal"], "reference")
                self.assertEqual(reference["confidence_direction"], "up")
                self.assertFalse(reference["source_type_increases_confidence"])
                self.assertFalse(reference["safe_to_act"])
                self.assertFalse(reference["durable_memory_claimed"])
                self.assertIn("source type authority", reference["does_not_prove"])

                successful = store.record_reinforcement_update(
                    "memcand-reinforce-1",
                    signal="successful_use",
                    reason="helped avoid repeating a previous implementation gap",
                    evidence_refs=["trace:trace-reinforce-1", "review:synthetic-success"],
                )
                self.assertEqual(successful["signal"], "successful_use")
                summary = store.get_summary("memcand-reinforce-1")
                self.assertEqual(summary["reinforcement"]["reference_count"], 1)
                self.assertEqual(summary["reinforcement"]["success_use_count"], 1)
                self.assertIn("reference", summary["reinforcement"]["reinforcement_events"])
                self.assertIn("successful_use", summary["reinforcement"]["reinforcement_events"])
                self.assertEqual(summary["importance"], "medium")
                self.assertFalse(summary["durable_memory_claimed"])
            finally:
                store.close()

    def test_explicit_importance_and_failure_prevention_raise_importance_not_authority(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-important-1",
                        "trace_id": "trace-important-1",
                        "turn_id": "turn-important-1",
                        "summary": "A synthetic safety reminder can gain importance.",
                        "tags": ["safety"],
                        "source_refs": ["trace:trace-important-1"],
                    }
                )
                update = store.record_reinforcement_update(
                    "memcand-important-1",
                    signal="failure_prevention",
                    reason="prevented recurrence of a review-blocking failure",
                    evidence_refs=["trace:trace-important-1"],
                )
                summary = store.get_summary("memcand-important-1")
                self.assertEqual(update["strength_delta"], 0.2)
                self.assertEqual(summary["importance"], "high")
                self.assertEqual(summary["reinforcement"]["failure_prevention_count"], 1)
                self.assertFalse(summary["safe_to_act"])
                self.assertFalse(summary["durable_memory_claimed"])
                self.assertTrue(summary["must_revalidate_current_state"])
            finally:
                store.close()

    def test_correction_signal_reduces_confidence_direction_without_deleting(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-correction-1",
                        "trace_id": "trace-correction-1",
                        "turn_id": "turn-correction-1",
                        "summary": "A synthetic memory later receives a correction.",
                        "tags": ["explicit_remember"],
                        "source_refs": ["trace:trace-correction-1"],
                    }
                )
                store.record_reinforcement_update(
                    "memcand-correction-1",
                    signal="explicit_importance",
                    reason="initially important to remember",
                    evidence_refs=["trace:trace-correction-1"],
                )
                correction = store.record_reinforcement_update(
                    "memcand-correction-1",
                    signal="correction",
                    reason="later correction supersedes part of the memory",
                    evidence_refs=["trace:trace-correction-1", "review:synthetic-correction"],
                )
                summary = store.get_summary("memcand-correction-1")
                self.assertEqual(correction["confidence_direction"], "down")
                self.assertLess(correction["strength_delta"], 0)
                self.assertEqual(summary["status"], "reinforcement_correction_recorded")
                self.assertEqual(summary["reinforcement"]["correction_count"], 1)
                self.assertEqual(summary["reinforcement"]["last_confidence_direction"], "down")
                self.assertTrue(summary["normal_retrieval_allowed"])
                self.assertNotEqual(summary["lifecycle_action"], "delete")
            finally:
                store.close()

    def test_quarantine_and_deletion_precede_reinforcement(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-reinforce-unsafe-1",
                        "trace_id": "trace-reinforce-unsafe-1",
                        "turn_id": "turn-reinforce-unsafe-1",
                        "summary": "Unsafe synthetic record should not be reinforced.",
                        "tags": ["explicit_remember"],
                        "source_refs": ["trace:trace-reinforce-unsafe-1"],
                        "private_path_dynamic_hint": "X:\\synthetic-private\\memory.txt",
                    }
                )
                with self.assertRaises(ValueError):
                    store.record_reinforcement_update(
                        "memcand-reinforce-unsafe-1",
                        signal="reference",
                        reason="should not override quarantine",
                        evidence_refs=["trace:trace-reinforce-unsafe-1"],
                    )

                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-reinforce-delete-1",
                        "trace_id": "trace-reinforce-delete-1",
                        "turn_id": "turn-reinforce-delete-1",
                        "summary": "Deletion request remains stronger than reinforcement.",
                        "tags": ["explicit_remember", "deletion_request"],
                        "source_refs": ["trace:trace-reinforce-delete-1"],
                    }
                )
                with self.assertRaises(ValueError):
                    store.record_reinforcement_update(
                        "memcand-reinforce-delete-1",
                        signal="explicit_importance",
                        reason="should not override deletion request",
                        evidence_refs=["trace:trace-reinforce-delete-1"],
                    )
            finally:
                store.close()

    def test_reinforcement_filters_unsafe_update_inputs_and_preserves_revalidation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-reinforce-state-1",
                        "trace_id": "trace-reinforce-state-1",
                        "turn_id": "turn-reinforce-state-1",
                        "summary": "A synthetic historical state observation can be referenced later.",
                        "tags": ["current_state", "safety"],
                        "source_refs": ["trace:trace-reinforce-state-1"],
                        "state_value": "synthetic_state_observed",
                        "observed_at": "2026-06-12T00:00:00Z",
                        "source_author": "synthetic_environment_state",
                        "evidence_layer": "historical_observation",
                    }
                )
                update = store.record_reinforcement_update(
                    "memcand-reinforce-state-1",
                    signal="reference",
                    reason="X:\\synthetic-private\\should-not-appear.txt",
                    evidence_refs=["trace:trace-reinforce-state-1", "provider_payload:synthetic"],
                )
                summary = store.get_summary("memcand-reinforce-state-1")
                serialized_update = json.dumps(update, sort_keys=True)
                serialized_summary = json.dumps(summary, sort_keys=True)
                self.assertEqual(update["reason"], "redacted reinforcement reason")
                self.assertEqual(update["evidence_refs"], ["trace:trace-reinforce-state-1"])
                self.assertTrue(summary["must_revalidate_current_state"])
                self.assertEqual(summary["state_observation"]["state_semantic_class"], "historical_observation")
                self.assertNotIn("synthetic-private", serialized_update)
                self.assertNotIn("provider_payload", serialized_update)
                self.assertNotIn("synthetic-private", serialized_summary)
                self.assertFalse(update["llm_final_authority"])
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
