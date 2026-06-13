from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from memory_core.store import MemoryStore


UNSAFE_STRINGS = [
    "synthetic-raw-user-text",
    "synthetic-raw-transcript",
    "synthetic-provider-payload",
    "synthetic-token-value",
    "X:\\synthetic-private\\memory.txt",
    "light.synthetic_fixture",
    "entity:light.synthetic_fixture",
    "synthetic-raw-log-marker",
    "raw_screenshot:synthetic-frame",
]


class MemoryCoreRecordTests(unittest.TestCase):
    def test_records_redacted_candidate_and_omits_unsafe_fields(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / "memory.sqlite"
            store = MemoryStore(db_path)
            try:
                store.initialize()
                summary = store.record_candidate(
                    {
                        "schema_version": "memory_candidate.v0",
                        "memory_candidate_id": "memcand-record-1",
                        "trace_id": "trace-record-1",
                        "turn_id": "turn-record-1",
                        "summary": "User corrected a prior action result; recheck before acting.",
                        "tags": ["user_feedback", "action_result", "entity:light.synthetic_fixture"],
                        "source_refs": ["trace:trace-record-1", "event:event-record-1", "entity:light.synthetic_fixture"],
                        "safe_to_act": True,
                        "durable_memory_claimed": True,
                        "raw_prompt": "synthetic-raw-user-text",
                        "raw_transcript": "synthetic-raw-transcript",
                        "provider_payload_dynamic_hint": "synthetic-provider-payload",
                        "confirmation_token": "synthetic-token-value",
                        "private_path_dynamic_hint": "X:\\synthetic-private\\memory.txt",
                        "raw_log_marker": "synthetic-raw-log-marker",
                        "raw_screenshot_ref": "raw_screenshot:synthetic-frame",
                        "action": {"target": "light.synthetic_fixture"},
                    }
                )
                serialized = json.dumps(summary, sort_keys=True)
                self.assertEqual(summary["record_id"], "memcand-record-1")
                self.assertEqual(summary["schema_version"], "memory_candidate.v0")
                self.assertEqual(summary["status"], "candidate_quarantined")
                self.assertTrue(summary["safety"]["unsafe_quarantine"])
                self.assertIn("unsafe_key_or_ref", summary["safety"]["unsafe_reason_codes"])
                self.assertFalse(summary["normal_retrieval_allowed"])
                self.assertFalse(summary["safe_to_act"])
                self.assertFalse(summary["durable_memory_claimed"])
                self.assertTrue(summary["must_revalidate_current_state"])
                self.assertIn("user_feedback", summary["tags"])
                for unsafe in UNSAFE_STRINGS:
                    self.assertNotIn(unsafe, serialized)
            finally:
                store.close()
            db_bytes = db_path.read_bytes()
            for unsafe in UNSAFE_STRINGS:
                self.assertNotIn(unsafe.encode("utf-8"), db_bytes)


if __name__ == "__main__":
    unittest.main()
