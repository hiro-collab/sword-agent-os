"""Reader-safe Memory Core summaries."""

from __future__ import annotations

import json
import sqlite3
from typing import Any
from uuid import uuid4

from .schema import ALLOWED_RETRIEVAL_DEPTHS, MEMORY_CONTEXT_REF_VERSION, validate_shareable_payload


def _row_value(row: sqlite3.Row, field: str, default: Any = None) -> Any:
    if field not in row.keys():
        return default
    return row[field]


def row_to_summary(row: sqlite3.Row) -> dict[str, Any]:
    content = json.loads(row["content_json"])
    memory_policy = content.get("memory_policy", {})
    state_observation = content.get("state_observation", {})
    safety = content.get("safety", {})
    lifecycle = content.get("lifecycle", {})
    reinforcement = content.get("reinforcement", {})
    relations = content.get("relations", {})
    resolved_issue = content.get("resolved_issue", {})
    summary = {
        "schema_version": row["schema_version"],
        "record_id": row["id"],
        "summary": row["summary"],
        "trace_id": row["trace_id"],
        "turn_id": row["turn_id"],
        "episode_id": row["episode_id"],
        "status": row["status"],
        "freshness": row["freshness"],
        "importance": row["importance"],
        "familiarity": row["familiarity"],
        "protected_state": row["protected_state"],
        "ingest_priority": _row_value(row, "ingest_priority", memory_policy.get("ingest_priority", "normal")),
        "priority_tags": memory_policy.get("priority_tags", []),
        "priority_policy_id": memory_policy.get("priority_policy_id"),
        "priority_policy_version": memory_policy.get("priority_policy_version"),
        "priority_reasons": memory_policy.get("priority_reasons", []),
        "retention_class": _row_value(
            row, "retention_class", memory_policy.get("retention_class", "ordinary_candidate")
        ),
        "memory_tier": memory_policy.get("memory_tier", "long_term" if memory_policy.get("long_term") else "ordinary"),
        "long_term_kind": memory_policy.get("long_term_kind"),
        "long_term": bool(_row_value(row, "long_term", memory_policy.get("long_term", False))),
        "memory_granularity": _row_value(
            row, "memory_granularity", memory_policy.get("memory_granularity", "candidate")
        ),
        "deletion_requested": bool(
            _row_value(row, "deletion_requested", memory_policy.get("deletion_requested", False))
        ),
        "lifecycle_action": _row_value(row, "lifecycle_action", memory_policy.get("lifecycle_action", "none")),
        "normal_retrieval_allowed": bool(
            _row_value(row, "normal_retrieval_allowed", memory_policy.get("normal_retrieval_allowed", True))
        ),
        "history_retrieval_allowed": bool(
            _row_value(row, "history_retrieval_allowed", memory_policy.get("history_retrieval_allowed", True))
        ),
        "physical_delete_required": bool(
            _row_value(row, "physical_delete_required", memory_policy.get("physical_delete_required", False))
        ),
        "state_observation": {
            "state_semantic_class": _row_value(
                row, "state_semantic_class", state_observation.get("state_semantic_class", "memory_candidate")
            ),
            "evidence_layer": _row_value(
                row, "evidence_layer", state_observation.get("evidence_layer", "candidate_summary")
            ),
            "observed_at": _row_value(row, "observed_at", state_observation.get("observed_at")),
            "fresh_until": _row_value(row, "fresh_until", state_observation.get("fresh_until")),
            "source_author": _row_value(row, "source_author", state_observation.get("source_author")),
            "source_refs_present": state_observation.get("source_refs_present", False),
            "metadata_complete_for_normal_retrieval": state_observation.get(
                "metadata_complete_for_normal_retrieval", True
            ),
            "retrieval_block_reason": state_observation.get("retrieval_block_reason"),
            "must_revalidate_current_state": bool(row["must_revalidate_current_state"]),
        },
        "safety": {
            "unsafe_quarantine": bool(_row_value(row, "unsafe_quarantine", safety.get("unsafe_quarantine", False))),
            "unsafe_reason_codes": safety.get("unsafe_reason_codes", []),
        },
        "reinforcement": reinforcement,
        "relation_metadata": relations,
        "resolved_issue": resolved_issue,
        "lifecycle": lifecycle,
        "safe_to_act": bool(row["safe_to_act"]),
        "durable_memory_claimed": bool(row["durable_memory_claimed"]),
        "must_revalidate_current_state": bool(row["must_revalidate_current_state"]),
        "tags": content.get("tags", []),
        "source_refs": content.get("source_refs", []),
        "does_not_prove": content.get("does_not_prove", []),
        "organization": content.get("organization", {}),
        "redaction": content.get("redaction", {}),
    }
    return summary


def build_memory_context_ref(
    *,
    retrieval_depth: str,
    query_reason: str,
    tags_used: tuple[str, ...],
    trace_ids_used: tuple[str, ...],
    turn_ids_used: tuple[str, ...],
    source_refs_used: tuple[str, ...],
    record_ids_requested: tuple[str, ...],
    results: list[dict[str, Any]],
    blocked_results: list[dict[str, str]],
    max_results: int,
    broad_scan_performed: bool = False,
) -> dict[str, Any]:
    """Build a reader-safe memory context reference for later-turn use."""

    if retrieval_depth not in ALLOWED_RETRIEVAL_DEPTHS:
        raise ValueError("unsupported retrieval depth")

    result_ids = [summary["record_id"] for summary in results]
    revalidation_required_ids = [
        summary["record_id"]
        for summary in results
        if summary.get("must_revalidate_current_state")
        or summary.get("state_observation", {}).get("must_revalidate_current_state")
    ]
    context = {
        "schema_version": MEMORY_CONTEXT_REF_VERSION,
        "context_ref_id": f"memory-context-{uuid4().hex}",
        "retrieval_depth": retrieval_depth,
        "query_reason": query_reason,
        "tags_used": list(tags_used),
        "trace_ids_used": list(trace_ids_used),
        "turn_ids_used": list(turn_ids_used),
        "source_refs_used": list(source_refs_used),
        "record_ids_requested": list(record_ids_requested),
        "result_count": len(results),
        "max_results": max_results,
        "result_ids": result_ids,
        "results": results,
        "blocked_results": blocked_results,
        "revalidation_required_record_ids": revalidation_required_ids,
        "current_state_revalidated": False,
        "safe_to_act": False,
        "durable_memory_claimed": False,
        "broad_scan_performed": broad_scan_performed,
        "does_not_prove": [
            "current state truth",
            "future safety",
            "durable production memory",
            "provider quality",
            "issue closure",
            "live action approval",
            "RR003 representative pass",
        ],
        "non_claims": [
            "not_all_memory_read",
            "not_current_state_without_revalidation",
            "not_runtime_writer_proof",
            "not_production_durable_memory",
        ],
        "redaction": {
            "shareable_summary_only": True,
            "prompt_material_included": False,
            "transcript_material_included": False,
            "provider_body_included": False,
            "credential_material_included": False,
            "local_ref_included": False,
            "device_ref_included": False,
            "media_material_included": False,
        },
    }
    validate_shareable_payload(context)
    return context
