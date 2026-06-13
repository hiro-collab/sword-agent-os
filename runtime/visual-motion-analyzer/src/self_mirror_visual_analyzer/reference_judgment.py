from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any


JUDGMENT_SCHEMA_VERSION = "self_mirror_auto_judgment_result.v0"
REFERENCE_CASE_SCHEMA_VERSION = "self_mirror_reference_case.v0"
PROFILE_SCHEMA_VERSION = "self_mirror_auto_judgment_profile.v0"

_UNSAFE_STRING_MARKERS = (
    ":\\",
    "\\users\\",
    "/users/",
    "raw-browser-frames",
    "self_mirror_browser_config",
    ".png",
    ".jpg",
    ".jpeg",
    ".webm",
    ".mp4",
    ".wav",
    ".jsonl",
    "authorization:",
    "bearer ",
    "sk-",
)

_FORBIDDEN_TRUE_KEYS = {
    "raw_frame_included",
    "raw_screenshot_included",
    "raw_video_included",
    "raw_audio_included",
    "raw_transcript_included",
    "provider_payload_included",
    "local_path_included",
    "secret_included",
    "device_entity_id_included",
    "raw_log_included",
    "raw_freeform_text_included",
    "raw_artifact_retained",
    "direct_correction_dispatch",
    "issue_closure_authority",
    "git_or_publication_authority",
}


def load_reference_case(path: str | Path) -> dict[str, Any]:
    payload = _load_json(path)
    _require_schema(payload, REFERENCE_CASE_SCHEMA_VERSION, "reference case")
    _assert_redacted(payload, "reference case")
    return payload


def load_auto_judgment_profile(path: str | Path) -> dict[str, Any]:
    payload = _load_json(path)
    _require_schema(payload, PROFILE_SCHEMA_VERSION, "auto judgment profile")
    _assert_redacted(payload, "auto judgment profile")
    return payload


def judge_metric_summary(
    summary: dict[str, Any],
    profile: dict[str, Any] | None,
    reference_cases: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Return an observation-only automatic judgment for a metric summary.

    The function only uses redacted summary/profile/reference data. It does not
    read frames, screenshots, logs, browser state, or local paths.
    """

    _assert_redacted(summary, "metric summary")
    cases = reference_cases or []
    for case in cases:
        _assert_redacted(case, "reference case")

    if not profile:
        return _judgment(
            "unclear",
            0.0,
            True,
            ["profile-missing"],
            profile={},
            reference_cases=[],
            false_positive_source="unknown",
        )
    _assert_redacted(profile, "auto judgment profile")

    scenario_id = str(summary.get("scenario_id", ""))
    if str(profile.get("scenario_id", "")) != scenario_id:
        return _judgment(
            "unclear",
            0.0,
            True,
            ["profile-scenario-mismatch"],
            profile=profile,
            reference_cases=[],
            false_positive_source="unknown",
        )

    if str(profile.get("status", "")) not in {"active", "calibration"}:
        return _judgment(
            "unclear",
            _summary_confidence(summary),
            True,
            ["profile-not-active"],
            profile=profile,
            reference_cases=[],
            false_positive_source="unknown",
        )

    matched_cases = _matching_reference_cases(profile, cases, scenario_id)
    coverage_reasons = _coverage_gaps(profile, matched_cases)
    if coverage_reasons:
        return _judgment(
            "unclear",
            _summary_confidence(summary),
            True,
            coverage_reasons,
            profile=profile,
            reference_cases=matched_cases,
            false_positive_source="unknown",
        )

    run_ref_reasons = _run_ref_gaps(summary, profile, matched_cases)
    if run_ref_reasons:
        return _judgment(
            "unclear",
            _summary_confidence(summary),
            True,
            run_ref_reasons,
            profile=profile,
            reference_cases=matched_cases,
            false_positive_source="unknown",
        )

    metrics = _metrics_by_roi_and_window(summary)
    expected_roi_ids = list(
        profile.get("minimum_reference_coverage", {}).get("required_roi_ids", [])
    )
    thresholds = profile.get("thresholds", {})
    confidence_model = profile.get("confidence_model", {})

    pretrigger_reasons = _pretrigger_reasons(metrics, expected_roi_ids, thresholds)
    if pretrigger_reasons:
        return _judgment(
            "unclear",
            _summary_confidence(summary),
            True,
            pretrigger_reasons,
            profile=profile,
            reference_cases=matched_cases,
            false_positive_source="pretrigger_motion",
        )

    guard_reason = _guard_false_positive_reason(metrics, expected_roi_ids, thresholds)
    if guard_reason:
        return _judgment(
            "unclear",
            _summary_confidence(summary),
            True,
            [guard_reason],
            profile=profile,
            reference_cases=matched_cases,
            false_positive_source="ui_or_layout_guard_motion",
        )

    pass_count, active_reasons, active_confidence = _active_expected_roi_result(
        metrics,
        expected_roi_ids,
        thresholds,
    )
    min_pass_count = int(thresholds.get("min_expected_roi_pass_count", len(expected_roi_ids)))
    summary_confidence = min(_summary_confidence(summary), active_confidence)
    min_confidence_for_pass = float(confidence_model.get("min_confidence_for_pass", 0.75))
    min_confidence_for_fail = float(confidence_model.get("min_confidence_for_fail", 0.6))

    if pass_count >= min_pass_count and summary_confidence >= min_confidence_for_pass:
        return _judgment(
            "pass",
            summary_confidence,
            False,
            ["auto-judgment-pass"],
            profile=profile,
            reference_cases=matched_cases,
            false_positive_source="none",
        )

    if summary_confidence < min_confidence_for_fail:
        return _judgment(
            "unclear",
            summary_confidence,
            True,
            ["low-confidence", *active_reasons],
            profile=profile,
            reference_cases=matched_cases,
            false_positive_source="unknown",
        )

    return _judgment(
        "fail",
        summary_confidence,
        False,
        ["expected-roi-motion-missing", *active_reasons],
        profile=profile,
        reference_cases=matched_cases,
        false_positive_source="none",
    )


def attach_auto_judgment(
    summary: dict[str, Any],
    judgment: dict[str, Any],
) -> dict[str, Any]:
    attached = copy.deepcopy(summary)
    attached["reference_profile_id"] = judgment.get("reference_profile_id", "")
    attached["threshold_profile_id"] = judgment.get("threshold_profile_id", "")
    attached["reference_case_refs"] = list(judgment.get("matched_reference_case_ids", []))
    attached["auto_judgment_result"] = judgment.get("result", "unclear")
    attached["auto_judgment"] = copy.deepcopy(judgment)
    attached["confidence"] = float(judgment.get("confidence", 0.0))
    attached["needs_human_review"] = bool(judgment.get("needs_human_review", True))
    does_not_prove = list(attached.get("does_not_prove", []))
    for non_claim in [
        "not_human_observation_authority",
        "not_semantic_dance_quality_proof",
        "not_physical_display_proof",
    ]:
        if non_claim not in does_not_prove:
            does_not_prove.append(non_claim)
    attached["does_not_prove"] = does_not_prove
    return attached


def _load_json(path: str | Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError("expected a JSON object")
    return payload


def _require_schema(payload: dict[str, Any], expected: str, label: str) -> None:
    if payload.get("schema_version") != expected:
        raise ValueError(f"{label} schema_version must be {expected}")


def _assert_redacted(payload: Any, label: str) -> None:
    errors = _redaction_errors(payload)
    if errors:
        raise ValueError(f"{label} contains unsafe shareable data: {', '.join(sorted(set(errors)))}")


def _redaction_errors(value: Any) -> list[str]:
    errors: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            if key in _FORBIDDEN_TRUE_KEYS and item is True:
                errors.append(key)
            errors.extend(_redaction_errors(item))
        return errors
    if isinstance(value, list):
        for item in value:
            errors.extend(_redaction_errors(item))
        return errors
    if isinstance(value, str):
        lowered = value.lower()
        for marker in _UNSAFE_STRING_MARKERS:
            if marker in lowered:
                errors.append(marker)
    return errors


def _matching_reference_cases(
    profile: dict[str, Any],
    cases: list[dict[str, Any]],
    scenario_id: str,
) -> list[dict[str, Any]]:
    wanted_refs = set(profile.get("reference_case_refs", []))
    matched: list[dict[str, Any]] = []
    for case in cases:
        if case.get("schema_version") != REFERENCE_CASE_SCHEMA_VERSION:
            continue
        if case.get("scenario_id") != scenario_id:
            continue
        if wanted_refs and case.get("reference_case_id") not in wanted_refs:
            continue
        matched.append(case)
    return matched


def _coverage_gaps(profile: dict[str, Any], cases: list[dict[str, Any]]) -> list[str]:
    coverage = profile.get("minimum_reference_coverage", {})
    reasons: list[str] = []
    min_total = int(coverage.get("minimum_reference_cases", 0))
    min_pass = int(coverage.get("min_pass_cases", 0))
    min_fail_or_unclear = int(coverage.get("min_fail_or_unclear_cases", 0))

    if len(cases) < min_total:
        reasons.append("insufficient-reference-coverage")
    pass_count = sum(1 for case in cases if case.get("expected_result") == "pass")
    fail_or_unclear_count = sum(
        1 for case in cases if case.get("expected_result") in {"fail", "unclear"}
    )
    if pass_count < min_pass:
        reasons.append("insufficient-pass-reference-coverage")
    if fail_or_unclear_count < min_fail_or_unclear:
        reasons.append("insufficient-fail-or-unclear-reference-coverage")

    covered_rois: set[str] = set()
    covered_false_positive_categories: set[str] = set()
    for case in cases:
        covered_rois.update(case.get("roi_set", {}).get("expected_roi_ids", []))
        labels = case.get("human_observation_labels", {})
        if isinstance(labels, dict):
            covered_false_positive_categories.update(
                str(category)
                for category in labels.get("false_positive_categories", [])
                if category and category != "not_collected"
            )
    for roi_id in coverage.get("required_roi_ids", []):
        if roi_id not in covered_rois:
            reasons.append(f"reference-roi-missing:{roi_id}")
    for category in coverage.get("required_false_positive_categories", []):
        if category not in covered_false_positive_categories:
            reasons.append(f"reference-false-positive-category-missing:{category}")
    return reasons


def _run_ref_gaps(
    summary: dict[str, Any],
    profile: dict[str, Any],
    cases: list[dict[str, Any]],
) -> list[str]:
    policy = profile.get("run_ref_policy", {})
    required_fields = list(policy.get("required_fields", []))
    summary_refs = summary.get("run_refs", {})
    reasons = [
        f"run-ref-missing:{field}"
        for field in required_fields
        if not summary_refs.get(field)
    ]
    if reasons:
        return reasons

    if not bool(policy.get("require_matching_refs_when_summary_id_matches", False)):
        return []

    summary_id = str(summary.get("summary_id", ""))
    for case in cases:
        metric_ref = case.get("metric_summary_ref", {})
        if metric_ref.get("summary_id") != summary_id:
            continue
        case_refs = case.get("run_refs", {})
        for field in required_fields:
            if case_refs.get(field) != summary_refs.get(field):
                reasons.append(f"run-ref-mismatch:{field}")
    return reasons


def _metrics_by_roi_and_window(summary: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    metrics: dict[tuple[str, str], dict[str, Any]] = {}
    for metric in summary.get("roi_window_metrics", []):
        if not isinstance(metric, dict):
            continue
        metrics[(str(metric.get("roi_id", "")), str(metric.get("time_window", "")))] = metric
    return metrics


def _pretrigger_reasons(
    metrics: dict[tuple[str, str], dict[str, Any]],
    expected_roi_ids: list[str],
    thresholds: dict[str, Any],
) -> list[str]:
    max_allowed = float(thresholds.get("pretrigger_quiet_max_movement_score", 0.0))
    reasons: list[str] = []
    for roi_id in expected_roi_ids:
        metric = metrics.get((roi_id, "pretrigger"), {})
        if float(metric.get("movement_score", 0.0)) > max_allowed:
            reasons.append(f"pretrigger-motion:{roi_id}")
    return reasons


def _guard_false_positive_reason(
    metrics: dict[tuple[str, str], dict[str, Any]],
    expected_roi_ids: list[str],
    thresholds: dict[str, Any],
) -> str:
    max_avatar = max(
        (
            float(metrics.get((roi_id, "active"), {}).get("movement_score", 0.0))
            for roi_id in expected_roi_ids
        ),
        default=0.0,
    )
    max_guard = max(
        (
            float(metric.get("movement_score", 0.0))
            for (roi_id, window), metric in metrics.items()
            if window == "active" and roi_id not in expected_roi_ids
        ),
        default=0.0,
    )
    guard_max = float(thresholds.get("guard_ui_motion_max_score", 1.0))
    ratio_max = float(thresholds.get("guard_to_avatar_ratio_max", 1.5))
    if max_guard <= guard_max:
        return ""
    if max_avatar <= 0:
        return "guard-motion-without-avatar-motion"
    if (max_guard / max_avatar) > ratio_max:
        return "guard-motion-dominates-avatar-motion"
    return ""


def _active_expected_roi_result(
    metrics: dict[tuple[str, str], dict[str, Any]],
    expected_roi_ids: list[str],
    thresholds: dict[str, Any],
) -> tuple[int, list[str], float]:
    active_thresholds = thresholds.get("active_motion_min_score_by_roi", {})
    changed_thresholds = thresholds.get("active_changed_ratio_min_by_roi", {})
    min_samples = int(thresholds.get("min_consecutive_samples", 1))
    pass_count = 0
    reasons: list[str] = []
    confidences: list[float] = []
    for roi_id in expected_roi_ids:
        metric = metrics.get((roi_id, "active"))
        if not metric:
            reasons.append(f"active-metric-missing:{roi_id}")
            confidences.append(0.0)
            continue
        movement_score = float(metric.get("movement_score", 0.0))
        changed_ratio = float(metric.get("changed_ratio", 0.0))
        sample_count = int(metric.get("sample_count", 0))
        confidence = float(metric.get("confidence", 0.0))
        confidences.append(confidence)
        score_threshold = float(active_thresholds.get(roi_id, active_thresholds.get("*", 0.0)))
        changed_threshold = float(changed_thresholds.get(roi_id, changed_thresholds.get("*", 0.0)))
        if sample_count < min_samples:
            reasons.append(f"sample-count-too-low:{roi_id}")
            continue
        if movement_score < score_threshold:
            reasons.append(f"movement-score-too-low:{roi_id}")
            continue
        if changed_ratio < changed_threshold:
            reasons.append(f"changed-ratio-too-low:{roi_id}")
            continue
        pass_count += 1
    return pass_count, reasons, min(confidences, default=0.0)


def _summary_confidence(summary: dict[str, Any]) -> float:
    if "confidence" in summary:
        return _bounded_float(summary.get("confidence"))
    latest_state = summary.get("latest_state", {})
    if isinstance(latest_state, dict) and "confidence" in latest_state:
        return _bounded_float(latest_state.get("confidence"))
    values = [
        _bounded_float(metric.get("confidence"))
        for metric in summary.get("roi_window_metrics", [])
        if isinstance(metric, dict) and metric.get("time_window") == "active"
    ]
    return min(values, default=0.0)


def _bounded_float(value: Any) -> float:
    try:
        return round(max(0.0, min(1.0, float(value))), 3)
    except (TypeError, ValueError):
        return 0.0


def _judgment(
    result: str,
    confidence: float,
    needs_human_review: bool,
    reason_codes: list[str],
    *,
    profile: dict[str, Any],
    reference_cases: list[dict[str, Any]],
    false_positive_source: str,
) -> dict[str, Any]:
    return {
        "schema_version": JUDGMENT_SCHEMA_VERSION,
        "result": result,
        "confidence": _bounded_float(confidence),
        "needs_human_review": needs_human_review,
        "reason_codes": reason_codes,
        "matched_reference_case_ids": [
            str(case.get("reference_case_id", "")) for case in reference_cases
        ],
        "threshold_profile_id": str(profile.get("threshold_profile_id", "")),
        "reference_profile_id": str(profile.get("profile_id", "")),
        "profile_status": str(profile.get("status", "")),
        "suspected_false_positive_source": false_positive_source,
        "manual_observation_used": False,
        "manual_observation_ref": "not_collected",
        "observation_only": True,
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_video_included": False,
        "local_path_included": False,
        "direct_correction_dispatch": False,
        "issue_closure_authority": False,
        "git_or_publication_authority": False,
    }
