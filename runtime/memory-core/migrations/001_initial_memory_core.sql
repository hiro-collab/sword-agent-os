CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS memory_records (
  id TEXT PRIMARY KEY,
  schema_version TEXT NOT NULL,
  summary TEXT NOT NULL,
  trace_id TEXT,
  turn_id TEXT,
  episode_id TEXT,
  status TEXT NOT NULL,
  freshness TEXT NOT NULL,
  importance TEXT NOT NULL,
  familiarity TEXT NOT NULL,
  protected_state TEXT NOT NULL,
  safe_to_act INTEGER NOT NULL DEFAULT 0,
  durable_memory_claimed INTEGER NOT NULL DEFAULT 0,
  must_revalidate_current_state INTEGER NOT NULL DEFAULT 1,
  content_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_tags (
  record_id TEXT NOT NULL,
  tag TEXT NOT NULL,
  PRIMARY KEY (record_id, tag),
  FOREIGN KEY (record_id) REFERENCES memory_records(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS memory_source_refs (
  record_id TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  PRIMARY KEY (record_id, source_ref),
  FOREIGN KEY (record_id) REFERENCES memory_records(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS memory_relations (
  record_id TEXT NOT NULL,
  relation_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  PRIMARY KEY (record_id, relation_type, target_id),
  FOREIGN KEY (record_id) REFERENCES memory_records(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_memory_records_trace_id ON memory_records(trace_id);
CREATE INDEX IF NOT EXISTS idx_memory_records_turn_id ON memory_records(turn_id);
CREATE INDEX IF NOT EXISTS idx_memory_records_episode_id ON memory_records(episode_id);
CREATE INDEX IF NOT EXISTS idx_memory_records_status ON memory_records(status);
CREATE INDEX IF NOT EXISTS idx_memory_tags_tag ON memory_tags(tag);
CREATE INDEX IF NOT EXISTS idx_memory_source_refs_source_ref ON memory_source_refs(source_ref);

