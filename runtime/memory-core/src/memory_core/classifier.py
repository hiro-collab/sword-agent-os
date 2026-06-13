"""Deterministic Memory/Issue classifier for reader-safe summaries."""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from .schema import (
    safe_bool,
    safe_non_negative_int,
    safe_string,
    safe_string_list,
    unsafe_reason_codes,
    validate_shareable_payload,
)

CLASSIFICATION_SCHEMA_VERSION = "memory_issue_classification.v0"

ROUTE_TRACE_ONLY = "trace_only"
ROUTE_MEMORY_CANDIDATE = "memory_candidate"
ROUTE_ISSUE_CANDIDATE = "issue_candidate"
ROUTE_BOTH = "both"
ROUTE_NEEDS_LLM = "needs_llm_classification"
ROUTE_NEEDS_HUMAN = "needs_human_review"

ALLOWED_CLASSIFICATION_ROUTES = (
    ROUTE_TRACE_ONLY,
    ROUTE_MEMORY_CANDIDATE,
    ROUTE_ISSUE_CANDIDATE,
    ROUTE_BOTH,
    ROUTE_NEEDS_LLM,
    ROUTE_NEEDS_HUMAN,
)

EXTERNAL_SIDE_EFFECT_CLASSES = {
    "external_side_effect",
    "home_control",
    "device_action",
    "live_action",
    "git_action",
    "publication",
    "source_adoption",
    "env_config",
    "provider_call",
}

EXTERNAL_ACTION_KINDS = {
    "home_control",
    "device_action",
    "live_action",
    "git_action",
    "publication",
    "source_adoption",
    "env_config",
    "provider_call",
}

DELETION_TAGS = {"deletion_request", "deletion_requested", "delete_requested"}
RESOLVED_TAGS = {"resolved", "resolved_issue", "regression_reference"}
MEMORY_TAGS = {"explicit_remember", "user_correction", "long_term_candidate", "safety"}
ISSUE_TAGS = {"failure_pattern", "review_blocker", "repeated_failure"}


def classify_memory_issue_route(event_summary: dict[str, Any]) -> dict[str, Any]:
    """Classify a bounded event summary into memory/issue routing.

    This helper is intentionally source-no-live and side-effect free. It does
    not write memory, create issues, call an LLM/provider, or authorize actions.
    """

    if not isinstance(event_summary, dict):
        payload: dict[str, Any] = {"input_shape": "unsupported"}
        unsupported_input = True
    else:
        payload = event_summary
        unsupported_input = False

    trace_id = safe_string(payload.get("trace_id"), max_length=96)
    turn_id = safe_string(payload.get("turn_id"), max_length=96)
    event_id = safe_string(payload.get("event_id"), max_length=96)
    source_refs = safe_string_list(payload.get("source_refs"), max_items=16, max_length=120)
    tags = safe_string_list(payload.get("tags"), max_items=20, max_length=64)
    route_hints = safe_string_list(payload.get("route_hints"), max_items=12, max_length=64)
    tag_set = set(tags)
    hint_set = set(route_hints)

    side_effect_class = safe_string(payload.get("side_effect_class"), max_length=64)
    action_kind = safe_string(payload.get("action_kind"), max_length=64)
    final_status = safe_string(payload.get("final_status"), max_length=64)
    state_semantic_class = safe_string(payload.get("state_semantic_class"), default="memory_candidate", max_length=64)
    observed_at = safe_string(payload.get("observed_at"), max_length=64)
    source_author = safe_string(payload.get("source_author"), max_length=96)
    retry_count = safe_non_negative_int(payload.get("retry_count"), maximum=1000)
    retry_limit = safe_non_negative_int(payload.get("retry_limit"), default=0, maximum=1000)
    repeat_count = safe_non_negative_int(payload.get("repeat_count"), default=0, maximum=100000)

    unsafe_reasons = unsafe_reason_codes(payload)
    reason_codes: list[str] = []

    def add_reason(reason: str) -> None:
        if reason not in reason_codes:
            reason_codes.append(reason)

    def has_any(items: set[str], candidates: set[str]) -> bool:
        return bool(items & candidates)

    current_state_like = (
        safe_bool(payload.get("current_state_like"), default=False)
        or payload.get("state_value") is not None
        or "current_state" in tag_set
        or state_semantic_class in {"current_state", "state_observation", "historical_observation"}
    )
    has_current_source = bool(observed_at and (source_author or source_refs))
    must_revalidate = (
        safe_bool(payload.get("must_revalidate_current_state"), default=False) or current_state_like
    )
    deletion_request = (
        has_any(tag_set, DELETION_TAGS)
        or has_any(hint_set, DELETION_TAGS)
        or safe_string(payload.get("lifecycle_action"), max_length=64) in {"delete", "forget", "deprecate"}
    )
    external_side_effect = (
        side_effect_class in EXTERNAL_SIDE_EFFECT_CLASSES
        or action_kind in EXTERNAL_ACTION_KINDS
        or has_any(hint_set, EXTERNAL_SIDE_EFFECT_CLASSES | EXTERNAL_ACTION_KINDS)
    )
    resolved_context = (
        has_any(tag_set, RESOLVED_TAGS)
        or safe_string(payload.get("resolved_issue_ref"), max_length=120) is not None
        or safe_string(payload.get("regression_reference"), max_length=120) is not None
    )
    failure_pattern = (
        safe_bool(payload.get("failure_pattern"), default=False)
        or has_any(tag_set, ISSUE_TAGS)
        or has_any(hint_set, ISSUE_TAGS)
        or repeat_count >= 2
    )
    retry_exhausted = retry_limit > 0 and retry_count >= retry_limit and final_status in {
        "failed",
        "gave_up",
        "retry_exhausted",
    }
    review_blocker = "review_blocker" in tag_set or "review_blocker" in hint_set
    explicit_memory = has_any(tag_set, MEMORY_TAGS) or has_any(hint_set, MEMORY_TAGS)
    llm_semantic_needed = (
        safe_bool(payload.get("llm_semantic_needed"), default=False)
        or safe_bool(payload.get("needs_llm_classification"), default=False)
        or "semantic_ambiguous" in tag_set
        or "semantic_ambiguous" in hint_set
    )

    route = ROUTE_TRACE_ONLY
    deterministic_safety_stop = False
    llm_advisory_allowed = False

    if unsupported_input:
        route = ROUTE_NEEDS_HUMAN
        deterministic_safety_stop = True
        add_reason("unsupported_input_shape")
    elif unsafe_reasons:
        route = ROUTE_NEEDS_HUMAN
        deterministic_safety_stop = True
        add_reason("unsafe_input_detected")
        for reason in unsafe_reasons:
            add_reason(reason)
    elif external_side_effect:
        route = ROUTE_NEEDS_HUMAN
        deterministic_safety_stop = True
        add_reason("external_side_effect_requires_human_review")
    elif current_state_like and not has_current_source:
        route = ROUTE_TRACE_ONLY
        add_reason("current_state_metadata_missing")
    elif deletion_request:
        route = ROUTE_NEEDS_HUMAN
        deterministic_safety_stop = True
        add_reason("lifecycle_request_requires_human_review")
    elif resolved_context and (failure_pattern or retry_exhausted):
        route = ROUTE_BOTH
        add_reason("resolved_reference_with_fresh_failure")
    elif resolved_context:
        route = ROUTE_MEMORY_CANDIDATE
        add_reason("resolved_issue_history_context")
    elif failure_pattern or retry_exhausted or review_blocker:
        route = ROUTE_ISSUE_CANDIDATE
        if retry_exhausted:
            add_reason("retry_exhausted")
        if failure_pattern:
            add_reason("failure_pattern")
        if review_blocker:
            add_reason("review_blocker")
    elif explicit_memory:
        route = ROUTE_MEMORY_CANDIDATE
        add_reason("memory_candidate_signal")
    elif llm_semantic_needed:
        route = ROUTE_NEEDS_LLM
        llm_advisory_allowed = True
        add_reason("semantic_classification_needed")
    else:
        route = ROUTE_TRACE_ONLY
        add_reason("trace_only_low_impact")

    memory_candidate_allowed = route in {ROUTE_MEMORY_CANDIDATE, ROUTE_BOTH}
    issue_candidate_allowed = route in {ROUTE_ISSUE_CANDIDATE, ROUTE_BOTH}
    needs_human_review = route == ROUTE_NEEDS_HUMAN
    needs_llm_classification = route == ROUTE_NEEDS_LLM
    if needs_human_review or deterministic_safety_stop:
        llm_advisory_allowed = False

    candidate_tags = _candidate_tags(
        tag_set=tag_set,
        memory_candidate_allowed=memory_candidate_allowed,
        resolved_context=resolved_context,
        current_state_like=current_state_like,
    )
    issue_tags = _issue_tags(
        tag_set=tag_set,
        issue_candidate_allowed=issue_candidate_allowed,
        failure_pattern=failure_pattern,
        retry_exhausted=retry_exhausted,
        review_blocker=review_blocker,
    )

    classification = {
        "schema_version": CLASSIFICATION_SCHEMA_VERSION,
        "classification_id": f"memory-issue-classification-{uuid4().hex}",
        "trace_id": trace_id,
        "turn_id": turn_id,
        "event_id": event_id,
        "route": route,
        "reason_codes": reason_codes,
        "deterministic_safety_stop": deterministic_safety_stop,
        "candidate_tags": candidate_tags,
        "issue_tags": issue_tags,
        "needs_llm_classification": needs_llm_classification,
        "needs_human_review": needs_human_review,
        "llm_advisory_allowed": llm_advisory_allowed,
        "llm_final_authority": False,
        "memory_candidate_allowed": memory_candidate_allowed,
        "memory_write_allowed": memory_candidate_allowed,
        "issue_candidate_allowed": issue_candidate_allowed,
        "issue_publication_allowed": False,
        "issue_created": False,
        "current_state_revalidated": False,
        "must_revalidate_current_state": must_revalidate,
        "source_refs": list(source_refs),
        "safe_to_act": False,
        "durable_memory_claimed": False,
        "provider_called": False,
        "does_not_prove": _does_not_prove(resolved_context=resolved_context),
        "redaction": {
            "shareable_summary_only": True,
            "unsafe_input_echoed": False,
            "prompt_material_included": False,
            "conversation_material_included": False,
            "provider_body_included": False,
            "credential_material_included": False,
            "local_ref_included": False,
            "device_ref_included": False,
            "media_material_included": False,
        },
    }
    validate_shareable_payload(classification)
    return classification


def _candidate_tags(
    *,
    tag_set: set[str],
    memory_candidate_allowed: bool,
    resolved_context: bool,
    current_state_like: bool,
) -> list[str]:
    if not memory_candidate_allowed:
        return []
    tags: list[str] = []
    for tag in ("safety", "user_correction", "explicit_remember", "long_term_candidate"):
        if tag in tag_set:
            tags.append(tag)
    if resolved_context:
        for tag in ("resolved", "resolved_issue", "regression_reference"):
            if tag in tag_set and tag not in tags:
                tags.append(tag)
    if current_state_like and "historical_observation" not in tags:
        tags.append("historical_observation")
    return tags


def _issue_tags(
    *,
    tag_set: set[str],
    issue_candidate_allowed: bool,
    failure_pattern: bool,
    retry_exhausted: bool,
    review_blocker: bool,
) -> list[str]:
    if not issue_candidate_allowed:
        return []
    tags: list[str] = []
    if failure_pattern:
        tags.append("failure_pattern")
    if retry_exhausted:
        tags.append("retry_exhausted")
    if review_blocker:
        tags.append("review_blocker")
    for tag in ("resolved_issue", "regression_reference"):
        if tag in tag_set and tag not in tags:
            tags.append(tag)
    return tags


def _does_not_prove(*, resolved_context: bool) -> list[str]:
    non_claims = [
        "durable production memory",
        "current state truth",
        "future safety",
        "memory promotion",
        "issue publication",
        "issue closure",
        "provider quality",
        "live action approval",
        "Git publication",
        "review-ready",
        "strict release green",
        "RR003 representative pass",
    ]
    if resolved_context:
        non_claims.extend(["current failure", "fix still works"])
    return non_claims
