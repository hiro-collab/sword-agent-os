from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from memory_core.store import MemoryStore


class MemoryCoreReferenceTests(unittest.TestCase):
    def test_retrieves_reader_safe_summaries_by_id_trace_turn_tag_and_source_ref(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-reference-1",
                        "trace_id": "trace-reference-1",
                        "turn_id": "turn-reference-1",
                        "summary": "The result is historical evidence and must be revalidated.",
                        "tags": ["reference", "safe_summary"],
                        "source_refs": ["trace:trace-reference-1", "event:event-reference-1"],
                        "does_not_prove": ["current device state", "future safety"],
                    }
                )
                by_id = store.get_summary("memcand-reference-1")
                by_trace = store.find_by_trace_id("trace-reference-1")
                by_turn = store.find_by_turn_id("turn-reference-1")
                by_tag = store.find_by_tag("reference")
                by_source = store.find_by_source_ref("event:event-reference-1")
                for result in (by_id, by_trace[0], by_turn[0], by_tag[0], by_source[0]):
                    self.assertEqual(result["record_id"], "memcand-reference-1")
                    self.assertFalse(result["safe_to_act"])
                    self.assertFalse(result["durable_memory_claimed"])
                    self.assertTrue(result["must_revalidate_current_state"])
                    self.assertIn("current device state", result["does_not_prove"])
                    serialized = json.dumps(result, sort_keys=True)
                    self.assertNotIn("raw_prompt", serialized)
                    self.assertNotIn("provider_payload", serialized)
                    self.assertNotIn("entity_id", serialized)
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()

