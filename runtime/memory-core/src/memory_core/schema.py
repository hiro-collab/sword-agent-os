"""Schema helpers for redacted Memory Core records."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import json
import re
from typing import Any
from uuid import uuid4

SCHEMA_VERSION = "memory_candidate.v0"
MEMORY_CONTEXT_REF_VERSION = "memory_context_ref.v0"
PROMOTION_POLICY_ID = "memory_core_priority_promotion.v0"
PROMOTION_POLICY_VERSION = "2026-06-12"
PRIORITY_INGEST_POLICY_ID = "memory_core_priority_ingest.v0"
PRIORITY_INGEST_POLICY_VERSION = "2026-06-12"

ALLOWED_RETRIEVAL_DEPTHS = (
    "light_auto",
    "conditional_deep",
    "explicit_recall",
)

PRIORITY_INGEST_TAGS = (
    "safety",
    "user_correction",
    "review_blocker",
    "explicit_remember",
    "deletion_request",
    "deletion_requested",
    "long_term_candidate",
    "failure_pattern",
)

ALLOWED_PROMOTION_DECISIONS = (
    "promote",
    "hold",
    "reject",
    "merge",
    "quarantine",
    "superseded",
    "needs_human_review",
)

REINFORCEMENT_POLICY_ID = "memory_core_reinforcement_update.v0"
REINFORCEMENT_POLICY_VERSION = "2026-06-13"

ALLOWED_REINFORCEMENT_SIGNALS = (
    "reference",
    "rerecording",
    "similar_record",
    "successful_use",
    "explicit_importance",
    "failure_prevention",
    "work_continuity",
    "correction",
)

SENSITIVE_KEY_FRAGMENTS = (
    "raw_prompt",
    "raw_text",
    "raw_transcript",
    "transcript_raw",
    "provider_payload",
    "provider_response",
    "confirmation_token",
    "access_token",
    "bearer",
    "secret",
    "password",
    "private_path",
    "local_path",
    "raw_media",
    "raw_frame",
    "raw_screenshot",
    "raw_log",
    "entity_id",
    "ha_entity",
)

PRIVATE_PATH_PATTERN = re.compile(
    r"(?i)(?:[a-z]:\\(?:users|synthetic-private)\\|/users/|file://|\\\\[^\\]+\\)"
)
SECRET_VALUE_PATTERN = re.compile(r"(?i)\b(?:bearer|token|secret|password)\b")
HA_ENTITY_PATTERN = re.compile(
    r"(?i)(?:^|[:/])(?:light|switch|cover|script|sensor|binary_sensor|climate|vacuum)\.[a-z0-9_]+$"
)
RAW_REF_PATTERN = re.compile(r"(?i)(?:raw_|provider_payload|transcript|screenshot|frame)")


@dataclass(frozen=True)
class MemoryRecord:
    """A sanitized, candidate-compatible Memory Core record."""

    record_id: str
    schema_version: str
    summary: str
    trace_id: str | None
    turn_id: str | None
    episode_id: str | None
    tags: tuple[str, ...]
    source_refs: tuple[str, ...]
    does_not_prove: tuple[str, ...]
    safe_to_act: bool
    durable_memory_claimed: bool
    must_revalidate_current_state: bool
    protected_state: str
    ingest_priority: str
    priority_tags: tuple[str, ...]
    retention_class: str
    long_term: bool
    memory_granularity: str
    deletion_requested: bool
    lifecycle_action: str
    normal_retrieval_allowed: bool
    history_retrieval_allowed: bool
    physical_delete_required: bool
    state_semantic_class: str
    evidence_layer: str
    observed_at: str | None
    fresh_until: str | None
    source_author: str | None
    unsafe_quarantine: bool
    unsafe_reasons: tuple[str, ...]
    related_memory_ids: tuple[str, ...]
    same_topic_tags: tuple[str, ...]
    supersedes: tuple[str, ...]
    superseded_by: tuple[str, ...]
    derived_from_episode_id: str | None
    issue_ref: str | None
    resolved_at: str | None
    resolution_ref: str | None
    resolved_by: str | None
    regression_risk: str
    status: str
    freshness: str
    importance: str
    familiarity: str
    content: dict[str, Any]
    created_at: str
    updated_at: str

    def to_content_json(self) -> str:
        return json.dumps(self.content, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def looks_unsafe_key(key: str) -> bool:
    normalized = key.lower()
    return any(fragment in normalized for fragment in SENSITIVE_KEY_FRAGMENTS)


def looks_unsafe_value(value: Any) -> bool:
    if value is None or isinstance(value, bool | int | float):
        return False
    if isinstance(value, str):
        return any(
            pattern.search(value)
            for pattern in (PRIVATE_PATH_PATTERN, SECRET_VALUE_PATTERN, HA_ENTITY_PATTERN, RAW_REF_PATTERN)
        )
    if isinstance(value, dict):
        return any(looks_unsafe_key(str(key)) or looks_unsafe_value(item) for key, item in value.items())
    if isinstance(value, list | tuple | set):
        return any(looks_unsafe_value(item) for item in value)
    return True


def unsafe_reason_codes(payload: Any) -> tuple[str, ...]:
    """Return bounded reason codes without copying unsafe keys or values."""

    reasons: list[str] = []

    def add(reason: str) -> None:
        if reason not in reasons:
            reasons.append(reason)

    def walk(value: Any) -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                key_text = str(key)
                if looks_unsafe_key(key_text) or looks_unsafe_value(key_text):
                    add("unsafe_key_or_ref")
                if looks_unsafe_value(item):
                    add("unsafe_value")
                walk(item)
        elif isinstance(value, list | tuple | set):
            for item in value:
                walk(item)
        elif looks_unsafe_value(value):
            add("unsafe_value")

    walk(payload)
    return tuple(reasons)


def safe_string(value: Any, *, default: str | None = None, max_length: int = 240) -> str | None:
    if value is None or looks_unsafe_value(value):
        return default
    text = str(value).strip()
    if not text:
        return default
    return text[:max_length]


def safe_bool(value: Any, *, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    return default


def safe_non_negative_int(value: Any, *, default: int = 0, maximum: int = 1_000_000) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, int | float):
        return max(0, min(int(value), maximum))
    return default


def safe_string_list(value: Any, *, max_items: int = 16, max_length: int = 120) -> tuple[str, ...]:
    if value is None:
        return tuple()
    items = value if isinstance(value, list | tuple | set) else [value]
    output: list[str] = []
    for item in items:
        safe = safe_string(item, max_length=max_length)
        if safe is not None and safe not in output:
            output.append(safe)
        if len(output) >= max_items:
            break
    return tuple(output)


def validate_shareable_payload(payload: Any) -> None:
    """Raise if a shareable payload contains unsafe keys or values."""

    if isinstance(payload, dict):
        for key, value in payload.items():
            if looks_unsafe_key(str(key)):
                raise ValueError(f"unsafe shareable key: {key}")
            validate_shareable_payload(value)
    elif isinstance(payload, list | tuple):
        for value in payload:
            validate_shareable_payload(value)
    elif looks_unsafe_value(payload):
        raise ValueError("unsafe shareable value")


def build_memory_record(candidate: dict[str, Any], *, now: str | None = None) -> MemoryRecord:
    """Build a sanitized Memory Core record from a memory candidate-like dict."""

    timestamp = now or utc_now()
    record_id = safe_string(
        candidate.get("memory_candidate_id") or candidate.get("record_id") or candidate.get("id"),
        default=f"mem-{uuid4().hex}",
        max_length=96,
    )
    assert record_id is not None
    trace_id = safe_string(candidate.get("trace_id"), max_length=96)
    turn_id = safe_string(candidate.get("turn_id"), max_length=96)
    episode_id = safe_string(candidate.get("episode_id"), max_length=96)
    summary = safe_string(
        candidate.get("summary") or candidate.get("candidate_summary") or candidate.get("memory_summary"),
        default="redacted memory candidate",
        max_length=480,
    )
    assert summary is not None
    tags = safe_string_list(candidate.get("tags"))
    tag_set = set(tags)
    priority_tags = tuple(tag for tag in PRIORITY_INGEST_TAGS if tag in tag_set)
    ingest_priority = "priority" if priority_tags else "normal"
    source_refs = safe_string_list(candidate.get("source_refs") or candidate.get("trace_refs"))
    does_not_prove = safe_string_list(
        candidate.get("does_not_prove")
        or candidate.get("non_claims")
        or ["current state", "future safety", "physical-world truth"]
    )
    safe_to_act = False
    durable_memory_claimed = False
    must_revalidate = safe_bool(
        candidate.get("must_revalidate_current_state")
        or (candidate.get("safe_for_future_reasoning") or {}).get("must_revalidate_current_state"),
        default=True,
    )
    protected_state = safe_string(candidate.get("protected_state"), default="deletable_candidate", max_length=64)
    assert protected_state is not None
    unsafe_reasons = unsafe_reason_codes(candidate)
    unsafe_quarantine = bool(unsafe_reasons)
    deletion_requested = (
        safe_bool(candidate.get("deletion_requested"), default=False)
        or "deletion_requested" in tag_set
        or "deletion_request" in tag_set
    )
    long_term = safe_bool(candidate.get("long_term"), default=False) or "long_term_candidate" in tag_set
    memory_granularity = safe_string(
        candidate.get("memory_granularity") or candidate.get("long_term_kind"),
        default="candidate",
        max_length=64,
    )
    assert memory_granularity is not None
    retention_class = "long_term_candidate" if long_term else "ordinary_candidate"
    lifecycle_action = "delete_requested" if deletion_requested else "none"
    normal_retrieval_allowed = not (unsafe_quarantine or deletion_requested)
    history_retrieval_allowed = not unsafe_quarantine
    physical_delete_required = deletion_requested and unsafe_quarantine
    state_value_present = candidate.get("state_value") is not None or "current_state" in tag_set
    state_semantic_class = safe_string(
        candidate.get("state_semantic_class"),
        default="historical_observation" if state_value_present else "memory_candidate",
        max_length=64,
    )
    assert state_semantic_class is not None
    evidence_layer = safe_string(candidate.get("evidence_layer"), default="candidate_summary", max_length=64)
    assert evidence_layer is not None
    observed_at = safe_string(candidate.get("observed_at"), max_length=64)
    fresh_until = safe_string(candidate.get("fresh_until") or candidate.get("ttl_until"), max_length=64)
    source_author = safe_string(candidate.get("source_author"), max_length=96)
    if state_semantic_class != "memory_candidate" or state_value_present:
        must_revalidate = True
    is_current_state_like = state_semantic_class != "memory_candidate" or state_value_present
    has_current_state_source = bool(source_refs or source_author)
    current_state_metadata_missing = is_current_state_like and (not observed_at or not has_current_state_source)
    if current_state_metadata_missing:
        normal_retrieval_allowed = False
    related_memory_ids = safe_string_list(candidate.get("related_memory_ids"), max_items=16, max_length=96)
    same_topic_tags = safe_string_list(candidate.get("same_topic_tags"), max_items=16, max_length=64)
    supersedes = safe_string_list(candidate.get("supersedes"), max_items=16, max_length=96)
    superseded_by = safe_string_list(candidate.get("superseded_by"), max_items=16, max_length=96)
    derived_from_episode_id = safe_string(candidate.get("derived_from_episode_id"), max_length=96)
    issue_ref = safe_string(candidate.get("issue_ref"), max_length=96)
    resolved_at = safe_string(candidate.get("resolved_at"), max_length=64)
    resolution_ref = safe_string(candidate.get("resolution_ref"), max_length=120)
    resolved_by = safe_string(candidate.get("resolved_by"), max_length=96)
    regression_risk = safe_string(candidate.get("regression_risk"), default="unknown", max_length=64)
    assert regression_risk is not None
    reinforcement = {
        "observation_count": safe_non_negative_int(candidate.get("observation_count")),
        "reference_count": safe_non_negative_int(candidate.get("reference_count")),
        "similar_record_count": safe_non_negative_int(candidate.get("similar_record_count")),
        "success_use_count": safe_non_negative_int(candidate.get("success_use_count")),
        "correction_count": safe_non_negative_int(candidate.get("correction_count")),
        "refresh_count": safe_non_negative_int(candidate.get("refresh_count")),
        "reinforcement_events": list(safe_string_list(candidate.get("reinforcement_events"), max_items=12)),
        "source_type_increases_confidence": False,
    }

    content = {
        "schema_version": SCHEMA_VERSION,
        "record_id": record_id,
        "summary": summary,
        "trace_id": trace_id,
        "turn_id": turn_id,
        "episode_id": episode_id,
        "tags": list(tags),
        "source_refs": list(source_refs),
        "does_not_prove": list(does_not_prove),
        "safe_to_act": safe_to_act,
        "durable_memory_claimed": durable_memory_claimed,
        "must_revalidate_current_state": must_revalidate,
        "memory_policy": {
            "priority_policy_id": PRIORITY_INGEST_POLICY_ID,
            "priority_policy_version": PRIORITY_INGEST_POLICY_VERSION,
            "ingest_priority": ingest_priority,
            "priority_tags": list(priority_tags),
            "priority_reasons": [f"tag:{tag}" for tag in priority_tags],
            "retention_class": retention_class,
            "long_term": long_term,
            "memory_tier": "long_term" if long_term else "ordinary",
            "long_term_kind": memory_granularity if long_term else None,
            "memory_granularity": memory_granularity,
            "deletion_requested": deletion_requested,
            "lifecycle_action": lifecycle_action,
            "normal_retrieval_allowed": normal_retrieval_allowed,
            "history_retrieval_allowed": history_retrieval_allowed,
            "physical_delete_required": physical_delete_required,
        },
        "state_observation": {
            "state_semantic_class": state_semantic_class,
            "evidence_layer": evidence_layer,
            "observed_at": observed_at,
            "fresh_until": fresh_until,
            "source_author": source_author,
            "source_refs_present": bool(source_refs),
            "metadata_complete_for_normal_retrieval": not current_state_metadata_missing,
            "retrieval_block_reason": "missing_observed_or_source_metadata"
            if current_state_metadata_missing
            else None,
            "must_revalidate_current_state": must_revalidate,
        },
        "promotion": {
            "policy_id": PROMOTION_POLICY_ID,
            "policy_version": PROMOTION_POLICY_VERSION,
            "candidate_only": True,
            "durable_commit_decided": False,
            "llm_final_authority": False,
        },
        "relations": {
            "related_memory_ids": list(related_memory_ids),
            "same_topic_tags": list(same_topic_tags),
            "supersedes": list(supersedes),
            "superseded_by": list(superseded_by),
            "derived_from_episode_id": derived_from_episode_id,
            "merge_like_is_relation_only": True,
        },
        "resolved_issue": {
            "issue_ref": issue_ref,
            "resolved_at": resolved_at,
            "resolution_ref": resolution_ref,
            "resolved_by": resolved_by,
            "regression_risk": regression_risk,
            "does_not_prove_current_failure": True,
            "does_not_prove_fix_still_works": True,
        },
        "reinforcement": reinforcement,
        "safety": {
            "unsafe_quarantine": unsafe_quarantine,
            "unsafe_reason_codes": list(unsafe_reasons),
        },
        "redaction": {
            "shareable_summary_only": True,
            "unsafe_input_stored": False,
            "unsafe_provider_data_stored": False,
            "unsafe_credential_stored": False,
            "unsafe_media_stored": False,
            "unsafe_local_ref_stored": False,
            "unsafe_device_ref_stored": False,
        },
    }
    validate_shareable_payload(content)
    return MemoryRecord(
        record_id=record_id,
        schema_version=SCHEMA_VERSION,
        summary=summary,
        trace_id=trace_id,
        turn_id=turn_id,
        episode_id=episode_id,
        tags=tags,
        source_refs=source_refs,
        does_not_prove=does_not_prove,
        safe_to_act=safe_to_act,
        durable_memory_claimed=durable_memory_claimed,
        must_revalidate_current_state=must_revalidate,
        protected_state=protected_state,
        ingest_priority=ingest_priority,
        priority_tags=priority_tags,
        retention_class=retention_class,
        long_term=long_term,
        memory_granularity=memory_granularity,
        deletion_requested=deletion_requested,
        lifecycle_action=lifecycle_action,
        normal_retrieval_allowed=normal_retrieval_allowed,
        history_retrieval_allowed=history_retrieval_allowed,
        physical_delete_required=physical_delete_required,
        state_semantic_class=state_semantic_class,
        evidence_layer=evidence_layer,
        observed_at=observed_at,
        fresh_until=fresh_until,
        source_author=source_author,
        unsafe_quarantine=unsafe_quarantine,
        unsafe_reasons=unsafe_reasons,
        related_memory_ids=related_memory_ids,
        same_topic_tags=same_topic_tags,
        supersedes=supersedes,
        superseded_by=superseded_by,
        derived_from_episode_id=derived_from_episode_id,
        issue_ref=issue_ref,
        resolved_at=resolved_at,
        resolution_ref=resolution_ref,
        resolved_by=resolved_by,
        regression_risk=regression_risk,
        status="candidate_quarantined"
        if unsafe_quarantine
        else ("candidate_metadata_hold" if current_state_metadata_missing else "candidate_recorded"),
        freshness="unknown",
        importance="low",
        familiarity="new",
        content=content,
        created_at=timestamp,
        updated_at=timestamp,
    )
