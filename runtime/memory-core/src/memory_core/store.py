"""SQLite-backed minimal Memory Core store."""

from __future__ import annotations

from pathlib import Path
import json
import sqlite3
from typing import Any
from uuid import uuid4

from .migrations import apply_migrations
from .organize import build_lightweight_relations, organize_record
from .reference import build_memory_context_ref, row_to_summary
from .schema import (
    ALLOWED_RETRIEVAL_DEPTHS,
    ALLOWED_PROMOTION_DECISIONS,
    ALLOWED_REINFORCEMENT_SIGNALS,
    PROMOTION_POLICY_ID,
    PROMOTION_POLICY_VERSION,
    REINFORCEMENT_POLICY_ID,
    REINFORCEMENT_POLICY_VERSION,
    build_memory_record,
    safe_non_negative_int,
    safe_string,
    safe_string_list,
    utc_now,
    validate_shareable_payload,
)

DEFAULT_RETRIEVAL_DEPTH_LIMITS = {
    "light_auto": 3,
    "conditional_deep": 8,
    "explicit_recall": 20,
}

LOW_PRIORITY_HISTORY_TAGS = {"resolved", "resolved_issue", "regression_reference"}

REINFORCEMENT_COUNTERS = {
    "reference": "reference_count",
    "rerecording": "refresh_count",
    "similar_record": "similar_record_count",
    "successful_use": "success_use_count",
    "explicit_importance": "explicit_importance_count",
    "failure_prevention": "failure_prevention_count",
    "work_continuity": "work_continuity_count",
    "correction": "correction_count",
}


class MemoryStore:
    """Small SQLite Memory Core store for no-live Wave 1 verification."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.connection = sqlite3.connect(self.path)
        self.connection.row_factory = sqlite3.Row

    def close(self) -> None:
        self.connection.close()

    def initialize(self) -> None:
        apply_migrations(self.connection)

    def record_candidate(self, candidate: dict[str, Any]) -> dict[str, Any]:
        record = organize_record(build_memory_record(candidate))
        validate_shareable_payload(record.content)
        with self.connection:
            self.connection.execute(
                """
                INSERT OR REPLACE INTO memory_records(
                  id, schema_version, summary, trace_id, turn_id, episode_id,
                  status, freshness, importance, familiarity, protected_state,
                  safe_to_act, durable_memory_claimed, must_revalidate_current_state,
                  ingest_priority, priority_tags_json, retention_class, long_term,
                  memory_granularity, deletion_requested, lifecycle_action,
                  normal_retrieval_allowed, history_retrieval_allowed, physical_delete_required,
                  state_semantic_class, evidence_layer, observed_at, fresh_until, source_author,
                  unsafe_quarantine, unsafe_reasons_json, content_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    record.record_id,
                    record.schema_version,
                    record.summary,
                    record.trace_id,
                    record.turn_id,
                    record.episode_id,
                    record.status,
                    record.freshness,
                    record.importance,
                    record.familiarity,
                    record.protected_state,
                    int(record.safe_to_act),
                    int(record.durable_memory_claimed),
                    int(record.must_revalidate_current_state),
                    record.ingest_priority,
                    json.dumps(list(record.priority_tags), ensure_ascii=True, sort_keys=True),
                    record.retention_class,
                    int(record.long_term),
                    record.memory_granularity,
                    int(record.deletion_requested),
                    record.lifecycle_action,
                    int(record.normal_retrieval_allowed),
                    int(record.history_retrieval_allowed),
                    int(record.physical_delete_required),
                    record.state_semantic_class,
                    record.evidence_layer,
                    record.observed_at,
                    record.fresh_until,
                    record.source_author,
                    int(record.unsafe_quarantine),
                    json.dumps(list(record.unsafe_reasons), ensure_ascii=True, sort_keys=True),
                    record.to_content_json(),
                    record.created_at,
                    record.updated_at,
                ),
            )
            self.connection.execute("DELETE FROM memory_tags WHERE record_id = ?", (record.record_id,))
            self.connection.execute("DELETE FROM memory_source_refs WHERE record_id = ?", (record.record_id,))
            self.connection.execute("DELETE FROM memory_relations WHERE record_id = ?", (record.record_id,))
            self.connection.executemany(
                "INSERT INTO memory_tags(record_id, tag) VALUES (?, ?)",
                [(record.record_id, tag) for tag in record.tags],
            )
            self.connection.executemany(
                "INSERT INTO memory_source_refs(record_id, source_ref) VALUES (?, ?)",
                [(record.record_id, source_ref) for source_ref in record.source_refs],
            )
            self.connection.executemany(
                "INSERT INTO memory_relations(record_id, relation_type, target_id) VALUES (?, ?, ?)",
                [
                    (record.record_id, relation["relation_type"], relation["target_id"])
                    for relation in build_lightweight_relations(
                        trace_id=record.trace_id,
                        turn_id=record.turn_id,
                        episode_id=record.episode_id,
                        source_refs=record.source_refs,
                        related_memory_ids=record.related_memory_ids,
                        same_topic_tags=record.same_topic_tags,
                        supersedes=record.supersedes,
                        superseded_by=record.superseded_by,
                        derived_from_episode_id=record.derived_from_episode_id,
                    )
                ],
            )
        return self.get_summary(record.record_id)

    def get_summary(self, record_id: str) -> dict[str, Any]:
        row = self.connection.execute("SELECT * FROM memory_records WHERE id = ?", (record_id,)).fetchone()
        if row is None:
            raise KeyError(record_id)
        summary = row_to_summary(row)
        validate_shareable_payload(summary)
        return summary

    def find_by_trace_id(self, trace_id: str) -> list[dict[str, Any]]:
        return self._find(
            "SELECT * FROM memory_records WHERE normal_retrieval_allowed = 1 AND trace_id = ? ORDER BY created_at, id",
            trace_id,
        )

    def find_by_turn_id(self, turn_id: str) -> list[dict[str, Any]]:
        return self._find(
            "SELECT * FROM memory_records WHERE normal_retrieval_allowed = 1 AND turn_id = ? ORDER BY created_at, id",
            turn_id,
        )

    def find_by_tag(self, tag: str) -> list[dict[str, Any]]:
        return self._find(
            """
            SELECT memory_records.* FROM memory_records
            JOIN memory_tags ON memory_tags.record_id = memory_records.id
            WHERE memory_records.normal_retrieval_allowed = 1 AND memory_tags.tag = ?
            ORDER BY memory_records.created_at, memory_records.id
            """,
            tag,
        )

    def find_by_source_ref(self, source_ref: str) -> list[dict[str, Any]]:
        return self._find(
            """
            SELECT memory_records.* FROM memory_records
            JOIN memory_source_refs ON memory_source_refs.record_id = memory_records.id
            WHERE memory_records.normal_retrieval_allowed = 1 AND memory_source_refs.source_ref = ?
            ORDER BY memory_records.created_at, memory_records.id
            """,
            source_ref,
        )

    def retrieve_context(
        self,
        *,
        retrieval_depth: str,
        query_reason: str,
        tags: list[str] | tuple[str, ...] | None = None,
        trace_ids: list[str] | tuple[str, ...] | None = None,
        turn_ids: list[str] | tuple[str, ...] | None = None,
        source_refs: list[str] | tuple[str, ...] | None = None,
        record_ids: list[str] | tuple[str, ...] | None = None,
        max_results: int | None = None,
    ) -> dict[str, Any]:
        """Retrieve a bounded, reader-safe memory context reference."""

        safe_depth = safe_string(retrieval_depth, max_length=32)
        if safe_depth not in ALLOWED_RETRIEVAL_DEPTHS:
            raise ValueError("unsupported retrieval depth")
        safe_reason = safe_string(query_reason, default="unspecified_query", max_length=120)
        assert safe_reason is not None
        tags_used = safe_string_list(tags, max_items=12, max_length=64)
        trace_ids_used = safe_string_list(trace_ids, max_items=8, max_length=96)
        turn_ids_used = safe_string_list(turn_ids, max_items=8, max_length=96)
        source_refs_used = safe_string_list(source_refs, max_items=12, max_length=120)
        record_ids_requested = safe_string_list(record_ids, max_items=12, max_length=96)
        default_limit = DEFAULT_RETRIEVAL_DEPTH_LIMITS[safe_depth]
        result_limit = safe_non_negative_int(max_results, default=default_limit, maximum=default_limit)
        result_limit = result_limit or default_limit

        if not any((tags_used, trace_ids_used, turn_ids_used, source_refs_used, record_ids_requested)):
            return build_memory_context_ref(
                retrieval_depth=safe_depth,
                query_reason=safe_reason,
                tags_used=tags_used,
                trace_ids_used=trace_ids_used,
                turn_ids_used=turn_ids_used,
                source_refs_used=source_refs_used,
                record_ids_requested=record_ids_requested,
                results=[],
                blocked_results=[],
                max_results=result_limit,
            )

        summaries: list[dict[str, Any]] = []
        blocked_results: list[dict[str, str]] = []
        query_tags = set(tags_used)

        for record_id in record_ids_requested:
            try:
                self._append_context_summary(
                    summaries,
                    blocked_results,
                    self.get_summary(record_id),
                    retrieval_depth=safe_depth,
                    query_tags=query_tags,
                    limit=result_limit,
                )
            except KeyError:
                blocked_results.append({"record_id": record_id, "reason_code": "record_not_found"})

        for trace_id in trace_ids_used:
            for summary in self.find_by_trace_id(trace_id):
                self._append_context_summary(
                    summaries,
                    blocked_results,
                    summary,
                    retrieval_depth=safe_depth,
                    query_tags=query_tags,
                    limit=result_limit,
                )
        for turn_id in turn_ids_used:
            for summary in self.find_by_turn_id(turn_id):
                self._append_context_summary(
                    summaries,
                    blocked_results,
                    summary,
                    retrieval_depth=safe_depth,
                    query_tags=query_tags,
                    limit=result_limit,
                )
        for tag in tags_used:
            for summary in self.find_by_tag(tag):
                self._append_context_summary(
                    summaries,
                    blocked_results,
                    summary,
                    retrieval_depth=safe_depth,
                    query_tags=query_tags,
                    limit=result_limit,
                )
        for source_ref in source_refs_used:
            for summary in self.find_by_source_ref(source_ref):
                self._append_context_summary(
                    summaries,
                    blocked_results,
                    summary,
                    retrieval_depth=safe_depth,
                    query_tags=query_tags,
                    limit=result_limit,
                )

        context = build_memory_context_ref(
            retrieval_depth=safe_depth,
            query_reason=safe_reason,
            tags_used=tags_used,
            trace_ids_used=trace_ids_used,
            turn_ids_used=turn_ids_used,
            source_refs_used=source_refs_used,
            record_ids_requested=record_ids_requested,
            results=summaries[:result_limit],
            blocked_results=blocked_results,
            max_results=result_limit,
        )
        validate_shareable_payload(context)
        return context

    def record_promotion_decision(
        self,
        record_id: str,
        *,
        decision: str,
        reasons: list[str] | tuple[str, ...],
        evidence_refs: list[str] | tuple[str, ...],
        confidence: float = 0.0,
        decided_by: str = "memory_core_policy",
        llm_final_authority: bool = False,
    ) -> dict[str, Any]:
        safe_decision = safe_string(decision, max_length=32)
        if safe_decision not in ALLOWED_PROMOTION_DECISIONS:
            raise ValueError("unsupported promotion decision")
        if llm_final_authority:
            raise ValueError("llm output cannot be final promotion authority")
        row = self.connection.execute("SELECT * FROM memory_records WHERE id = ?", (record_id,)).fetchone()
        if row is None:
            raise KeyError(record_id)
        if safe_decision == "promote" and (row["unsafe_quarantine"] or row["deletion_requested"]):
            raise ValueError("unsafe or deletion-requested memory cannot be promoted")

        decision_id = f"promotion-{uuid4().hex}"
        timestamp = utc_now()
        safe_reasons = safe_string_list(reasons, max_items=12, max_length=120) or ("policy_evaluated",)
        safe_evidence_refs = safe_string_list(evidence_refs, max_items=16, max_length=120)
        safe_decided_by = safe_string(decided_by, default="memory_core_policy", max_length=96)
        assert safe_decided_by is not None
        bounded_confidence = max(0.0, min(float(confidence), 1.0))
        does_not_prove = ("durable production memory", "current state truth", "future safety", "issue-ticket closure")
        with self.connection:
            self.connection.execute(
                """
                INSERT INTO memory_promotion_decisions(
                  decision_id, record_id, decision, policy_id, policy_version,
                  reasons_json, evidence_refs_json, confidence, llm_final_authority,
                  decided_by, created_at, does_not_prove_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    decision_id,
                    record_id,
                    safe_decision,
                    PROMOTION_POLICY_ID,
                    PROMOTION_POLICY_VERSION,
                    json.dumps(list(safe_reasons), ensure_ascii=True, sort_keys=True),
                    json.dumps(list(safe_evidence_refs), ensure_ascii=True, sort_keys=True),
                    bounded_confidence,
                    0,
                    safe_decided_by,
                    timestamp,
                    json.dumps(list(does_not_prove), ensure_ascii=True, sort_keys=True),
                ),
            )
            new_status = f"promotion_{safe_decision}_recorded"
            normal_allowed = 0 if safe_decision in {"reject", "quarantine", "superseded"} else row["normal_retrieval_allowed"]
            self.connection.execute(
                "UPDATE memory_records SET status = ?, normal_retrieval_allowed = ?, updated_at = ? WHERE id = ?",
                (new_status, normal_allowed, timestamp, record_id),
            )
        return self.get_promotion_decision(decision_id)

    def get_promotion_decision(self, decision_id: str) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT * FROM memory_promotion_decisions WHERE decision_id = ?",
            (decision_id,),
        ).fetchone()
        if row is None:
            raise KeyError(decision_id)
        summary = {
            "decision_id": row["decision_id"],
            "record_id": row["record_id"],
            "candidate_id": row["record_id"],
            "decision": row["decision"],
            "policy_id": row["policy_id"],
            "policy_version": row["policy_version"],
            "reasons": json.loads(row["reasons_json"]),
            "matched_criteria": json.loads(row["reasons_json"]),
            "rejected_criteria": [],
            "evidence_refs": json.loads(row["evidence_refs_json"]),
            "confidence": row["confidence"],
            "llm_final_authority": bool(row["llm_final_authority"]),
            "decided_by": row["decided_by"],
            "created_at": row["created_at"],
            "does_not_prove": json.loads(row["does_not_prove_json"]),
        }
        validate_shareable_payload(summary)
        return summary

    def record_reinforcement_update(
        self,
        record_id: str,
        *,
        signal: str,
        reason: str,
        evidence_refs: list[str] | tuple[str, ...],
        decided_by: str = "memory_core_policy",
        source_type: str | None = None,
    ) -> dict[str, Any]:
        """Record a reader-safe reinforcement or correction signal."""

        safe_signal = safe_string(signal, max_length=48)
        if safe_signal not in ALLOWED_REINFORCEMENT_SIGNALS:
            raise ValueError("unsupported reinforcement signal")
        row = self.connection.execute("SELECT * FROM memory_records WHERE id = ?", (record_id,)).fetchone()
        if row is None:
            raise KeyError(record_id)
        if row["unsafe_quarantine"] or row["deletion_requested"] or row["lifecycle_action"] == "delete":
            raise ValueError("unsafe, deletion-requested, or deleted memory cannot be reinforced")

        content = json.loads(row["content_json"])
        reinforcement = dict(content.get("reinforcement", {}))
        counter = REINFORCEMENT_COUNTERS[safe_signal]
        reinforcement[counter] = safe_non_negative_int(reinforcement.get(counter)) + 1
        events = list(reinforcement.get("reinforcement_events", []))
        if safe_signal not in events:
            events.append(safe_signal)
        reinforcement["reinforcement_events"] = events[:16]
        reinforcement["last_signal"] = safe_signal
        reinforcement["last_reinforced_at"] = utc_now()
        reinforcement["source_type_increases_confidence"] = False
        reinforcement["source_type_seen"] = safe_string(source_type, default="not_used_for_confidence", max_length=64)

        confidence_direction = "down" if safe_signal == "correction" else "up"
        strength_delta = -0.2 if safe_signal == "correction" else self._reinforcement_strength_delta(safe_signal)
        reinforcement["last_confidence_direction"] = confidence_direction
        reinforcement["strength_score"] = self._bounded_strength_score(
            reinforcement.get("strength_score", 0.0),
            strength_delta,
        )

        safe_reason = safe_string(reason, default="redacted reinforcement reason", max_length=160)
        safe_evidence_refs = safe_string_list(evidence_refs, max_items=16, max_length=120)
        safe_decided_by = safe_string(decided_by, default="memory_core_policy", max_length=96)
        assert safe_reason is not None
        assert safe_decided_by is not None
        does_not_prove = (
            "durable production memory",
            "current state truth",
            "future safety",
            "issue-ticket closure",
            "source type authority",
        )
        update_id = f"reinforcement-{uuid4().hex}"
        timestamp = reinforcement["last_reinforced_at"]
        content["reinforcement"] = reinforcement
        new_importance = self._reinforced_importance(row["importance"], safe_signal)
        new_status = (
            "reinforcement_correction_recorded" if safe_signal == "correction" else "reinforcement_recorded"
        )
        validate_shareable_payload(content)

        with self.connection:
            self.connection.execute(
                """
                INSERT INTO memory_reinforcement_updates(
                  update_id, record_id, signal, policy_id, policy_version,
                  reason, evidence_refs_json, strength_delta, confidence_direction,
                  source_type_increases_confidence, decided_by, created_at,
                  does_not_prove_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    update_id,
                    record_id,
                    safe_signal,
                    REINFORCEMENT_POLICY_ID,
                    REINFORCEMENT_POLICY_VERSION,
                    safe_reason,
                    json.dumps(list(safe_evidence_refs), ensure_ascii=True, sort_keys=True),
                    strength_delta,
                    confidence_direction,
                    0,
                    safe_decided_by,
                    timestamp,
                    json.dumps(list(does_not_prove), ensure_ascii=True, sort_keys=True),
                ),
            )
            self.connection.execute(
                """
                UPDATE memory_records
                SET status = ?, importance = ?, content_json = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    new_status,
                    new_importance,
                    json.dumps(content, ensure_ascii=True, sort_keys=True, separators=(",", ":")),
                    timestamp,
                    record_id,
                ),
            )
        return self.get_reinforcement_update(update_id)

    def get_reinforcement_update(self, update_id: str) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT * FROM memory_reinforcement_updates WHERE update_id = ?",
            (update_id,),
        ).fetchone()
        if row is None:
            raise KeyError(update_id)
        summary = {
            "update_id": row["update_id"],
            "record_id": row["record_id"],
            "signal": row["signal"],
            "policy_id": row["policy_id"],
            "policy_version": row["policy_version"],
            "reason": row["reason"],
            "evidence_refs": json.loads(row["evidence_refs_json"]),
            "strength_delta": row["strength_delta"],
            "confidence_direction": row["confidence_direction"],
            "source_type_increases_confidence": bool(row["source_type_increases_confidence"]),
            "decided_by": row["decided_by"],
            "created_at": row["created_at"],
            "safe_to_act": False,
            "durable_memory_claimed": False,
            "llm_final_authority": False,
            "does_not_prove": json.loads(row["does_not_prove_json"]),
        }
        validate_shareable_payload(summary)
        return summary

    def record_lifecycle_event(
        self,
        record_id: str,
        *,
        lifecycle_action: str,
        reason: str,
        requested_by: str = "memory_core_policy",
        decided_by: str = "memory_core_policy",
    ) -> dict[str, Any]:
        safe_action = safe_string(lifecycle_action, max_length=32)
        if safe_action not in {"expire", "deprecate", "forget", "delete"}:
            raise ValueError("unsupported lifecycle action")
        if safe_action == "delete":
            return self.tombstone_memory(record_id, reason=reason, requested_by=requested_by, decided_by=decided_by)
        row = self.connection.execute("SELECT * FROM memory_records WHERE id = ?", (record_id,)).fetchone()
        if row is None:
            raise KeyError(record_id)
        timestamp = utc_now()
        event_id = f"lifecycle-{uuid4().hex}"
        safe_reason = safe_string(reason, default="redacted lifecycle reason", max_length=160)
        safe_requested_by = safe_string(requested_by, default="memory_core_policy", max_length=96)
        safe_decided_by = safe_string(decided_by, default="memory_core_policy", max_length=96)
        assert safe_reason is not None
        assert safe_requested_by is not None
        assert safe_decided_by is not None
        with self.connection:
            self.connection.execute(
                """
                INSERT INTO memory_lifecycle_events(
                  event_id, record_id, lifecycle_action, reason, requested_by,
                  decided_by, created_at, tombstone_ref, normal_retrieval_allowed,
                  history_retrieval_allowed, physical_delete_required
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event_id,
                    record_id,
                    safe_action,
                    safe_reason,
                    safe_requested_by,
                    safe_decided_by,
                    timestamp,
                    None,
                    0,
                    1,
                    0,
                ),
            )
            self.connection.execute(
                """
                UPDATE memory_records
                SET status = ?, lifecycle_action = ?, normal_retrieval_allowed = 0,
                    history_retrieval_allowed = 1, updated_at = ?
                WHERE id = ?
                """,
                (f"{safe_action}_recorded", safe_action, timestamp, record_id),
            )
        return self.get_summary(record_id)

    def tombstone_memory(
        self,
        record_id: str,
        *,
        reason: str,
        requested_by: str = "memory_core_policy",
        decided_by: str = "memory_core_policy",
    ) -> dict[str, Any]:
        row = self.connection.execute("SELECT * FROM memory_records WHERE id = ?", (record_id,)).fetchone()
        if row is None:
            raise KeyError(record_id)
        timestamp = utc_now()
        event_id = f"lifecycle-{uuid4().hex}"
        tombstone_ref = f"tombstone:{event_id}"
        safe_reason = safe_string(reason, default="redacted deletion request", max_length=160)
        safe_requested_by = safe_string(requested_by, default="memory_core_policy", max_length=96)
        safe_decided_by = safe_string(decided_by, default="memory_core_policy", max_length=96)
        assert safe_reason is not None
        assert safe_requested_by is not None
        assert safe_decided_by is not None
        content = {
            "schema_version": row["schema_version"],
            "record_id": record_id,
            "summary": "memory tombstoned",
            "lifecycle": {
                "event_id": event_id,
                "lifecycle_action": "delete",
                "reason": safe_reason,
                "requested_by": safe_requested_by,
                "decided_by": safe_decided_by,
                "tombstone_ref": tombstone_ref,
                "normal_retrieval_allowed": False,
                "history_retrieval_allowed": False,
                "physical_delete_required": False,
            },
            "does_not_prove": ["physical deletion from backups", "publication approval", "current truth"],
            "redaction": {"shareable_summary_only": True},
        }
        validate_shareable_payload(content)
        with self.connection:
            self.connection.execute(
                """
                INSERT INTO memory_lifecycle_events(
                  event_id, record_id, lifecycle_action, reason, requested_by,
                  decided_by, created_at, tombstone_ref, normal_retrieval_allowed,
                  history_retrieval_allowed, physical_delete_required
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event_id,
                    record_id,
                    "delete",
                    safe_reason,
                    safe_requested_by,
                    safe_decided_by,
                    timestamp,
                    tombstone_ref,
                    0,
                    0,
                    0,
                ),
            )
            self.connection.execute("DELETE FROM memory_tags WHERE record_id = ?", (record_id,))
            self.connection.execute("DELETE FROM memory_source_refs WHERE record_id = ?", (record_id,))
            self.connection.execute("DELETE FROM memory_relations WHERE record_id = ?", (record_id,))
            self.connection.execute(
                """
                UPDATE memory_records
                SET summary = ?, status = ?, lifecycle_action = ?, deletion_requested = 1,
                    normal_retrieval_allowed = 0, history_retrieval_allowed = 0,
                    physical_delete_required = 0, content_json = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    "memory tombstoned",
                    "deleted_tombstoned",
                    "delete",
                    json.dumps(content, ensure_ascii=True, sort_keys=True, separators=(",", ":")),
                    timestamp,
                    record_id,
                ),
            )
        return self.get_summary(record_id)

    def get_relations(self, record_id: str) -> list[dict[str, str]]:
        rows = self.connection.execute(
            "SELECT relation_type, target_id FROM memory_relations WHERE record_id = ? ORDER BY relation_type, target_id",
            (record_id,),
        ).fetchall()
        return [dict(row) for row in rows]

    def _find(self, sql: str, value: str) -> list[dict[str, Any]]:
        rows = self.connection.execute(sql, (value,)).fetchall()
        summaries = [row_to_summary(row) for row in rows]
        validate_shareable_payload(summaries)
        return summaries

    def _append_context_summary(
        self,
        summaries: list[dict[str, Any]],
        blocked_results: list[dict[str, str]],
        summary: dict[str, Any],
        *,
        retrieval_depth: str,
        query_tags: set[str],
        limit: int,
    ) -> None:
        record_id = summary["record_id"]
        if any(existing["record_id"] == record_id for existing in summaries):
            return
        if not summary.get("normal_retrieval_allowed", False):
            blocked_results.append({"record_id": record_id, "reason_code": "normal_retrieval_not_allowed"})
            return
        tags = set(summary.get("tags", []))
        if (
            retrieval_depth == "light_auto"
            and tags & LOW_PRIORITY_HISTORY_TAGS
            and not query_tags & LOW_PRIORITY_HISTORY_TAGS
        ):
            blocked_results.append({"record_id": record_id, "reason_code": "low_priority_history_excluded"})
            return
        if len(summaries) >= limit:
            return
        summaries.append(summary)

    def _reinforcement_strength_delta(self, signal: str) -> float:
        if signal in {"explicit_importance", "failure_prevention", "work_continuity"}:
            return 0.2
        return 0.1

    def _bounded_strength_score(self, current: Any, delta: float) -> float:
        try:
            current_value = float(current)
        except (TypeError, ValueError):
            current_value = 0.0
        return max(0.0, min(1.0, current_value + delta))

    def _reinforced_importance(self, current: str, signal: str) -> str:
        if signal in {"explicit_importance", "failure_prevention", "work_continuity"}:
            return "high"
        if signal == "correction":
            return {"high": "medium", "medium": "low"}.get(current, current)
        return "medium" if current == "low" else current
