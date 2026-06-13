CREATE TABLE IF NOT EXISTS memory_reinforcement_updates (
  update_id TEXT PRIMARY KEY,
  record_id TEXT NOT NULL,
  signal TEXT NOT NULL CHECK(signal IN ('reference', 'rerecording', 'similar_record', 'successful_use', 'explicit_importance', 'failure_prevention', 'work_continuity', 'correction')),
  policy_id TEXT NOT NULL,
  policy_version TEXT NOT NULL,
  reason TEXT NOT NULL,
  evidence_refs_json TEXT NOT NULL,
  strength_delta REAL NOT NULL DEFAULT 0.0,
  confidence_direction TEXT NOT NULL CHECK(confidence_direction IN ('up', 'down', 'unchanged')),
  source_type_increases_confidence INTEGER NOT NULL DEFAULT 0,
  decided_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  does_not_prove_json TEXT NOT NULL,
  FOREIGN KEY (record_id) REFERENCES memory_records(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_memory_reinforcement_updates_record_id ON memory_reinforcement_updates(record_id);
CREATE INDEX IF NOT EXISTS idx_memory_reinforcement_updates_signal ON memory_reinforcement_updates(signal);
