from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from memory_core.migrations import apply_migrations, get_schema_version


class MemoryCoreMigrationTests(unittest.TestCase):
    def test_applies_initial_schema_and_indexes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / "memory.sqlite"
            connection = sqlite3.connect(db_path)
            try:
                apply_migrations(connection)
                self.assertEqual(get_schema_version(connection), 3)
                tables = {
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type = 'table'"
                    ).fetchall()
                }
                self.assertIn("memory_records", tables)
                self.assertIn("memory_tags", tables)
                self.assertIn("memory_source_refs", tables)
                self.assertIn("memory_relations", tables)
                self.assertIn("memory_promotion_decisions", tables)
                self.assertIn("memory_lifecycle_events", tables)
                self.assertIn("memory_reinforcement_updates", tables)
                indexes = {
                    row[1]
                    for row in connection.execute("PRAGMA index_list('memory_records')").fetchall()
                }
                self.assertIn("idx_memory_records_trace_id", indexes)
                self.assertIn("idx_memory_records_turn_id", indexes)
                self.assertIn("idx_memory_records_episode_id", indexes)
                self.assertIn("idx_memory_records_ingest_priority", indexes)
                reinforcement_indexes = {
                    row[1]
                    for row in connection.execute(
                        "PRAGMA index_list('memory_reinforcement_updates')"
                    ).fetchall()
                }
                self.assertIn("idx_memory_reinforcement_updates_record_id", reinforcement_indexes)
            finally:
                connection.close()


if __name__ == "__main__":
    unittest.main()
