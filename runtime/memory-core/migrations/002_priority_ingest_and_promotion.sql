ALTER TABLE memory_records ADD COLUMN ingest_priority TEXT NOT NULL DEFAULT 'normal';
ALTER TABLE memory_records ADD COLUMN priority_tags_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE memory_records ADD COLUMN retention_class TEXT NOT NULL DEFAULT 'ordinary_candidate';
ALTER TABLE memory_records ADD COLUMN long_term INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_records ADD COLUMN memory_granularity TEXT NOT NULL DEFAULT 'candidate';
ALTER TABLE memory_records ADD COLUMN deletion_requested INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_records ADD COLUMN lifecycle_action TEXT NOT NULL DEFAULT 'none';
ALTER TABLE memory_records ADD COLUMN normal_retrieval_allowed INTEGER NOT NULL DEFAULT 1;
ALTER TABLE memory_records ADD COLUMN history_retrieval_allowed INTEGER NOT NULL DEFAULT 1;
ALTER TABLE memory_records ADD COLUMN physical_delete_required INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_records ADD COLUMN state_semantic_class TEXT NOT NULL DEFAULT 'memory_candidate';
ALTER TABLE memory_records ADD COLUMN evidence_layer TEXT NOT NULL DEFAULT 'candidate_summary';
ALTER TABLE memory_records ADD COLUMN observed_at TEXT;
ALTER TABLE memory_records ADD COLUMN fresh_until TEXT;
ALTER TABLE memory_records ADD COLUMN source_author TEXT;
ALTER TABLE memory_records ADD COLUMN unsafe_quarantine INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_records ADD COLUMN unsafe_reasons_json TEXT NOT NULL DEFAULT '[]';

CREATE TABLE IF NOT EXISTS memory_promotion_decisions (
  decision_id TEXT PRIMARY KEY,
  record_id TEXT NOT NULL,
  decision TEXT NOT NULL CHECK(decision IN ('promote', 'hold', 'reject', 'merge', 'quarantine', 'superseded', 'needs_human_review')),
  policy_id TEXT NOT NULL,
  policy_version TEXT NOT NULL,
  reasons_json TEXT NOT NULL,
  evidence_refs_json TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  llm_final_authority INTEGER NOT NULL DEFAULT 0,
  decided_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  does_not_prove_json TEXT NOT NULL,
  FOREIGN KEY (record_id) REFERENCES memory_records(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS memory_lifecycle_events (
  event_id TEXT PRIMARY KEY,
  record_id TEXT NOT NULL,
  lifecycle_action TEXT NOT NULL CHECK(lifecycle_action IN ('expire', 'deprecate', 'forget', 'delete', 'delete_requested', 'tombstone')),
  reason TEXT NOT NULL,
  requested_by TEXT NOT NULL,
  decided_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  tombstone_ref TEXT,
  normal_retrieval_allowed INTEGER NOT NULL DEFAULT 0,
  history_retrieval_allowed INTEGER NOT NULL DEFAULT 1,
  physical_delete_required INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (record_id) REFERENCES memory_records(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_memory_records_ingest_priority ON memory_records(ingest_priority);
CREATE INDEX IF NOT EXISTS idx_memory_records_retention_class ON memory_records(retention_class);
CREATE INDEX IF NOT EXISTS idx_memory_records_lifecycle_action ON memory_records(lifecycle_action);
CREATE INDEX IF NOT EXISTS idx_memory_records_normal_retrieval_allowed ON memory_records(normal_retrieval_allowed);
CREATE INDEX IF NOT EXISTS idx_memory_promotion_decisions_record_id ON memory_promotion_decisions(record_id);
CREATE INDEX IF NOT EXISTS idx_memory_lifecycle_events_record_id ON memory_lifecycle_events(record_id);
