"""Lightweight organization rules for candidate memory records."""

from __future__ import annotations

from dataclasses import replace
from datetime import UTC, datetime

from .schema import MemoryRecord


def _parse_timestamp(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def organize_record(record: MemoryRecord, *, now: str | None = None) -> MemoryRecord:
    reference_time = _parse_timestamp(now) if now else datetime.now(UTC)
    created_at = _parse_timestamp(record.created_at)
    freshness = "unknown"
    if created_at is not None:
        age_seconds = (reference_time - created_at).total_seconds()
        freshness = "fresh" if age_seconds <= 24 * 60 * 60 else "stale"

    tags = set(record.tags)
    high_priority_tags = {"safety", "review_blocker", "explicit_remember", "deletion_requested", "failure_pattern"}
    medium_priority_tags = {"correction", "user_correction", "user_feedback", "action_result", "long_term_candidate"}
    if record.unsafe_quarantine or high_priority_tags & tags:
        importance = "high"
    elif medium_priority_tags & tags:
        importance = "medium"
    else:
        importance = "low"
    familiarity = "linked" if len(record.source_refs) > 1 or record.trace_id or record.turn_id else "new"
    episode_id = record.episode_id or (f"episode:{record.turn_id}" if record.turn_id else None)
    if record.unsafe_quarantine:
        status = "candidate_quarantined"
    elif record.status == "candidate_metadata_hold":
        status = "candidate_metadata_hold"
    else:
        status = "candidate_organized"

    content = dict(record.content)
    memory_policy = dict(content.get("memory_policy", {}))
    memory_policy.update(
        {
            "ingest_priority": record.ingest_priority,
            "priority_tags": list(record.priority_tags),
            "normal_retrieval_allowed": record.normal_retrieval_allowed,
            "history_retrieval_allowed": record.history_retrieval_allowed,
        }
    )
    content.update(
        {
            "episode_id": episode_id,
            "memory_policy": memory_policy,
            "organization": {
                "status": status,
                "freshness": freshness,
                "importance": importance,
                "familiarity": familiarity,
                "ingest_priority": record.ingest_priority,
                "priority_tags": list(record.priority_tags),
                "lightweight_relations": build_lightweight_relations(
                    trace_id=record.trace_id,
                    turn_id=record.turn_id,
                    episode_id=episode_id,
                    source_refs=record.source_refs,
                    related_memory_ids=record.related_memory_ids,
                    same_topic_tags=record.same_topic_tags,
                    supersedes=record.supersedes,
                    superseded_by=record.superseded_by,
                    derived_from_episode_id=record.derived_from_episode_id,
                ),
            },
        }
    )
    return replace(
        record,
        episode_id=episode_id,
        status=status,
        freshness=freshness,
        importance=importance,
        familiarity=familiarity,
        content=content,
    )


def build_lightweight_relations(
    *,
    trace_id: str | None,
    turn_id: str | None,
    episode_id: str | None,
    source_refs: tuple[str, ...],
    related_memory_ids: tuple[str, ...] = tuple(),
    same_topic_tags: tuple[str, ...] = tuple(),
    supersedes: tuple[str, ...] = tuple(),
    superseded_by: tuple[str, ...] = tuple(),
    derived_from_episode_id: str | None = None,
) -> list[dict[str, str]]:
    relations: list[dict[str, str]] = []
    if trace_id:
        relations.append({"relation_type": "derived_from_trace", "target_id": trace_id})
    if turn_id:
        relations.append({"relation_type": "belongs_to_turn", "target_id": turn_id})
    if episode_id:
        relations.append({"relation_type": "belongs_to_episode", "target_id": episode_id})
    for source_ref in source_refs:
        relations.append({"relation_type": "has_source_ref", "target_id": source_ref})
    for memory_id in related_memory_ids:
        relations.append({"relation_type": "related_memory", "target_id": memory_id})
    for tag in same_topic_tags:
        relations.append({"relation_type": "same_topic_tag", "target_id": tag})
    for memory_id in supersedes:
        relations.append({"relation_type": "supersedes", "target_id": memory_id})
    for memory_id in superseded_by:
        relations.append({"relation_type": "superseded_by", "target_id": memory_id})
    if derived_from_episode_id:
        relations.append({"relation_type": "derived_from_episode", "target_id": derived_from_episode_id})
    return relations
