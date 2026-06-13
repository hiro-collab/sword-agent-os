from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from memory_core.store import MemoryStore


class MemoryCoreOrganizeTests(unittest.TestCase):
    def test_organizes_candidate_with_status_tags_and_lightweight_relations(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = MemoryStore(Path(temp_dir) / "memory.sqlite")
            try:
                store.initialize()
                summary = store.record_candidate(
                    {
                        "memory_candidate_id": "memcand-organize-1",
                        "trace_id": "trace-organize-1",
                        "turn_id": "turn-organize-1",
                        "summary": "A review result should be treated as feedback, not current state.",
                        "tags": ["user_feedback", "review"],
                        "source_refs": ["trace:trace-organize-1", "event:event-organize-1"],
                    }
                )
                self.assertEqual(summary["status"], "candidate_organized")
                self.assertEqual(summary["freshness"], "fresh")
                self.assertEqual(summary["importance"], "medium")
                self.assertEqual(summary["familiarity"], "linked")
                self.assertEqual(summary["episode_id"], "episode:turn-organize-1")
                relation_types = {row["relation_type"] for row in store.get_relations("memcand-organize-1")}
                self.assertIn("derived_from_trace", relation_types)
                self.assertIn("belongs_to_turn", relation_types)
                self.assertIn("belongs_to_episode", relation_types)
                self.assertIn("has_source_ref", relation_types)
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()

