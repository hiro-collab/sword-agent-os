from __future__ import annotations

from collections import defaultdict
from typing import Any


NON_CLAIMS = [
    "not_raw_media_proof",
    "not_raw_screenshot_proof",
    "not_physical_display_proof",
    "not_environment_vision",
    "not_external_room_or_light_proof",
    "not_home_assistant_state_proof",
    "not_physical_action_proof",
    "not_semantic_full_body_or_dance_quality_proof",
    "not_expression_request_or_runtime_result_proof",
    "not_expression_semantic_proof",
    "not_rr003_representative_pass",
]

RAW_PRIVATE_FLAG_KEYS = {
    "raw_frame_included",
    "raw_screenshot_included",
    "raw_video_included",
    "raw_media_included",
    "raw_log_included",
    "raw_path_included",
    "local_path_included",
    "private_path_included",
    "provider_payload_included",
    "raw_provider_payload_included",
    "cookies_included",
    "local_storage_included",
    "session_storage_included",
    "session_store_included",
    "passwords_included",
    "unrelated_tabs_included",
    "browser_storage_included",
    "home_control_or_device_state_included",
}


def build_self_mirror_metric_summary(
    visual_summary: dict[str, Any],
    rows: list[dict[str, Any]],
    *,
    timeline_artifact: str = "visual_motion_roi_timeseries.csv",
    chart_artifact: str = "visual_motion_chart.html",
    jsonl_artifact: str | None = None,
) -> dict[str, Any]:
    scenario = dict(visual_summary.get("scenario", {}))
    scenario_id = _safe_text(visual_summary.get("scenario_id", "unknown"), default="unknown")
    proof_layer = _safe_text(visual_summary.get("proof_layer", "unknown"), default="unknown")
    activation_sampling = _safe_text(visual_summary.get("activation_sampling", "event_driven"), default="event_driven")
    evidence_export = _safe_text(
        visual_summary.get("evidence_export", "verification_capture"),
        default="verification_capture",
    )
    classification = visual_summary.get("classification", {})
    if not isinstance(classification, dict):
        classification = {}
    reason_code = _safe_text(
        classification.get("reason_code", visual_summary.get("result", "unknown")),
        default="unknown",
    )
    result = _result_status(_safe_text(visual_summary.get("result", "unknown"), default="unknown"))
    summary_id = f"smm_sum_{_safe_slug(visual_summary.get('analysis_run_id', scenario_id))}"
    windows = {
        str(window.get("window_id")): {
            "start_ms": int(window.get("start_ms", 0)),
            "end_ms": int(window.get("end_ms", 0)),
        }
        for window in visual_summary.get("windows", [])
        if isinstance(window, dict)
    }
    roi_results = {
        str(roi.get("roi_id")): roi
        for roi in visual_summary.get("roi_results", [])
        if isinstance(roi, dict)
    }
    timeline_ref = {
        "kind": "csv",
        "artifact": timeline_artifact,
        "shared": True,
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "authority": False,
    }
    supporting_views: list[dict[str, Any]] = [
        {
            "kind": "html",
            "artifact": chart_artifact,
            "shared": False,
            "authority": False,
            "raw_frame_included": False,
            "raw_screenshot_included": False,
        }
    ]
    if jsonl_artifact:
        supporting_views.append(
            {
                "kind": "jsonl",
                "artifact": jsonl_artifact,
                "shared": True,
                "authority": False,
                "raw_frame_included": False,
                "raw_screenshot_included": False,
            }
        )
    summary_confidence = _summary_confidence(visual_summary)
    motion_diagnostics = _motion_diagnostics_summary(visual_summary)
    observability = _observability_block(
        visual_summary=visual_summary,
        rows=rows,
        windows=windows,
        roi_results=roi_results,
        motion_diagnostics=motion_diagnostics,
        reason_code=reason_code,
    )
    if result == "pass" and observability["observability_surface_status"] == "missing_surface_blocker":
        result = "blocked"
        reason_code = "missing-surface-blocker"
    needs_attention = result != "pass"
    recommended_correction = (
        _safe_text(classification.get("next_action", ""), default="")
        if needs_attention
        else ""
    )
    if needs_attention and not recommended_correction:
        recommended_correction = "Inspect the Self Mirror metric surface before making a visual proof claim."
    latest_state = _latest_state(
        summary_id=summary_id,
        visual_summary=visual_summary,
        scenario_id=scenario_id,
        observed_target=_observed_target(visual_summary),
        result=result,
        reason_code=reason_code,
        needs_attention=needs_attention,
        recommended_correction=recommended_correction,
        activation_sampling=activation_sampling,
        evidence_export=evidence_export,
        proof_layer=proof_layer,
    )
    return {
        "schema_version": "self_mirror_metric_summary.v0",
        "summary_id": summary_id,
        "analysis_run_id": _safe_text(visual_summary.get("analysis_run_id"), default="redacted_unknown"),
        "scenario_id": scenario_id,
        "observed_target": _observed_target(visual_summary),
        "test_observability": observability["test_observability"],
        "observability": observability,
        "run_refs": _run_refs(visual_summary),
        "capture_target_identity": _safe_dict(
            visual_summary.get("capture_target_identity", {})
        ),
        "controlled_chrome_observation": _safe_dict(
            visual_summary.get("controlled_chrome_observation", {})
        ),
        "event_timeline": _safe_dict(visual_summary.get("event_timeline", {})),
        "projection_visual_diagnostics": _safe_dict(
            visual_summary.get("projection_visual_diagnostics", {})
        ),
        "motion_diagnostics": motion_diagnostics,
        "activation_sampling": activation_sampling,
        "evidence_export": evidence_export,
        "observation_policy": _observation_policy(activation_sampling, evidence_export),
        "evidence_layer": _evidence_layer(proof_layer),
        "proof_layer": proof_layer,
        "result": result,
        "confidence": summary_confidence,
        "needs_attention": needs_attention,
        "needs_human_review": needs_attention,
        "observed_issue": _observed_issue(reason_code),
        "recommended_correction": recommended_correction,
        "latest_observation_ref": latest_state["observation_id"],
        "consumer_retry_policy": _consumer_retry_policy(latest_state["observation_id"]),
        "latest_state": latest_state,
        "observation_queue": {
            "schema_version": "self_mirror_observation_queue.v0",
            "retention": "bounded_ring_buffer",
            "max_entries": 8,
            "durable_memory_by_default": False,
            "raw_frame_included": False,
            "raw_screenshot_included": False,
            "raw_video_included": False,
            "local_path_included": False,
            "direct_correction_dispatch": False,
            "consumer_retry_policy": _consumer_retry_policy(latest_state["observation_id"]),
            "entries": [latest_state],
        },
        "classification": {
            "status": result,
            "reason_code": reason_code,
            "diagnostic_result": motion_diagnostics.get("diagnostic_result", ""),
            "event_window_classification": motion_diagnostics.get("event_window_classification", ""),
            "timeline_stage": motion_diagnostics.get("timeline_stage", ""),
            "available_anchor_ids": motion_diagnostics.get("available_anchor_ids", []),
            "missing_anchor_ids": motion_diagnostics.get("missing_anchor_ids", []),
            "observed_issue": _observed_issue(reason_code),
            "recommended_correction": recommended_correction,
            "recommendation_is_observation_only": True,
            "non_claims": NON_CLAIMS,
        },
        "timeline_ref": timeline_ref,
        "supporting_views": supporting_views,
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_media_included": False,
        "roi_window_metrics": _roi_window_metrics(
            visual_summary=visual_summary,
            rows=rows,
            windows=windows,
            roi_results=roi_results,
            timeline_ref=timeline_ref,
        ),
        "does_not_prove": NON_CLAIMS,
        "source": {
            "kind": _safe_text(visual_summary.get("source_ref", {}).get("kind", "unknown"), default="unknown"),
            "source_ref_id": _safe_text(
                visual_summary.get("source_ref", {}).get("source_ref_id", "redacted_unknown"),
                default="redacted_unknown",
            ),
            "raw_source_shared": False,
        },
        "scenario": {
            "scenario_key": _safe_text(scenario.get("scenario_key", ""), default=""),
            "label": _safe_text(scenario.get("label", ""), default=""),
            "expected_motion": _safe_text(scenario.get("expected_motion", ""), default=""),
            "runtime_join_required": bool(scenario.get("runtime_join_required", False)),
        },
        "artifact_policy": {
            "authority_product": "self_mirror_metric_summary.v0",
            "timeline_export_authority": False,
            "graph_export_authority": False,
            "raw_frames_shared": False,
            "raw_paths_shared": False,
            "raw_frames_retained": bool(visual_summary.get("artifact_policy", {}).get("raw_frames_retained", False)),
            "shareable_output": _observation_policy(activation_sampling, evidence_export)["shareable_output"],
        },
        "boundary": {
            "observes": "self/avatar/display output",
            "does_not_observe": [
                "external_room_environment",
                "room_light_state",
                "home_assistant_state",
                "physical_device_action",
            ],
            "decision_boundary": {
                "self_mirror_role": "observation_and_evaluation_only",
                "does_not_decide_correction": True,
                "does_not_execute_correction": True,
                "motion_runtime_owns_motion_execution": True,
                "thought_core_owns_decision": True,
            },
        },
    }


def _roi_window_metrics(
    *,
    visual_summary: dict[str, Any],
    rows: list[dict[str, Any]],
    windows: dict[str, dict[str, int]],
    roi_results: dict[str, dict[str, Any]],
    timeline_ref: dict[str, Any],
) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        if not isinstance(row, dict):
            continue
        grouped[(str(row.get("roi_id", "")), str(row.get("window_id", "")))].append(row)

    metrics: list[dict[str, Any]] = []
    for (roi_id, window_id), window_rows in sorted(grouped.items()):
        if not roi_id or not window_id:
            continue
        window = windows.get(window_id, {"start_ms": 0, "end_ms": 0})
        roi_result = roi_results.get(roi_id, {})
        movement_score = max((float(row.get("motion_score", 0.0)) for row in window_rows), default=0.0)
        changed_ratio = max((float(row.get("changed_pixel_ratio", 0.0)) for row in window_rows), default=0.0)
        threshold = float(visual_summary.get("thresholds", {}).get("active_motion_min_score", 0.0))
        metrics.append(
            {
                "roi_id": roi_id,
                "observed_target": _target_for_roi(roi_result),
                "time_window": window_id,
                "start_ms": window["start_ms"],
                "end_ms": window["end_ms"],
                "sample_count": len(window_rows),
                "movement_score": round(movement_score, 6),
                "changed_ratio": round(changed_ratio, 6),
                "confidence": _metric_confidence(movement_score, threshold, len(window_rows)),
                "evidence_layer": _evidence_layer(str(visual_summary.get("proof_layer", "unknown"))),
                "timeline_ref": timeline_ref,
                "raw_frame_included": False,
                "raw_screenshot_included": False,
                "counts_as_avatar_motion": bool(roi_result.get("counts_as_avatar_motion", False)),
                "expected_for_pass": bool(roi_result.get("expected_for_pass", False)),
                "pass_label": str(roi_result.get("pass_label", "")),
                "does_not_prove": NON_CLAIMS,
                "non_claims": NON_CLAIMS,
            }
        )
    return metrics


def _latest_state(
    *,
    summary_id: str,
    visual_summary: dict[str, Any],
    scenario_id: str,
    observed_target: str,
    result: str,
    reason_code: str,
    needs_attention: bool,
    recommended_correction: str,
    activation_sampling: str,
    evidence_export: str,
    proof_layer: str,
) -> dict[str, Any]:
    motion_diagnostics = _motion_diagnostics_summary(visual_summary)
    return {
        "schema_version": "self_mirror_observation.v0",
        "observation_id": f"smm_obs_{_safe_slug(visual_summary.get('analysis_run_id', summary_id))}",
        "summary_id": summary_id,
        "analysis_run_id": _safe_text(visual_summary.get("analysis_run_id"), default="redacted_unknown"),
        "scenario_id": scenario_id,
        "observed_target": observed_target,
        "activation_sampling": activation_sampling,
        "evidence_export": evidence_export,
        "evidence_layer": _evidence_layer(proof_layer),
        "result": result,
        "reason_code": reason_code,
        "diagnostic_result": motion_diagnostics.get("diagnostic_result", ""),
        "event_window_classification": motion_diagnostics.get("event_window_classification", ""),
        "timeline_stage": motion_diagnostics.get("timeline_stage", ""),
        "available_anchor_ids": motion_diagnostics.get("available_anchor_ids", []),
        "missing_anchor_ids": motion_diagnostics.get("missing_anchor_ids", []),
        "needs_attention": needs_attention,
        "observed_issue": _observed_issue(reason_code),
        "recommended_correction": recommended_correction,
        "confidence": _summary_confidence(visual_summary),
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_video_included": False,
        "local_path_included": False,
        "direct_correction_dispatch": False,
        "retry_authority": False,
        "consumer_retry_policy_ref": "consumer_retry_policy",
        "durable_memory_by_default": False,
        "does_not_prove": NON_CLAIMS,
    }


def _run_refs(summary: dict[str, Any]) -> dict[str, Any]:
    runtime_join = summary.get("runtime_join", {})
    if not isinstance(runtime_join, dict):
        runtime_join = {}
    return {
        "motion_event_id": _safe_text(summary.get("motion_event_id", ""), default=""),
        "stimulus_id": _safe_text(runtime_join.get("stimulus_id", summary.get("stimulus_id", "")), default=""),
        "stimulus_instance_id": _safe_text(summary.get("stimulus_instance_id", ""), default=""),
        "runtime_result_id": _safe_text(
            runtime_join.get("runtime_result_id", summary.get("driver_result_id", "")),
            default="",
        ),
        "driver_result_id": _safe_text(
            runtime_join.get("driver_result_id", summary.get("driver_result_id", "")),
            default="",
        ),
        "multi_stimulus_group_id": _safe_text(runtime_join.get("multi_stimulus_group_id", ""), default=""),
        "runtime_status": _safe_text(runtime_join.get("result_status", ""), default=""),
        "runtime_reason_code": _safe_text(runtime_join.get("result_reason_code", ""), default=""),
        "runtime_safe_visible_state": _safe_text(runtime_join.get("result_safe_visible_state", ""), default=""),
    }


def _observability_block(
    *,
    visual_summary: dict[str, Any],
    rows: list[dict[str, Any]],
    windows: dict[str, dict[str, int]],
    roi_results: dict[str, dict[str, Any]],
    motion_diagnostics: dict[str, Any],
    reason_code: str,
) -> dict[str, Any]:
    capture_target_identity = _safe_dict(
        visual_summary.get("capture_target_identity", {})
    )
    authority_roi_ids = _authority_roi_ids(roi_results)
    guard_roi_ids = _guard_roi_ids(roi_results)
    window_coverage = _window_coverage(
        rows=rows,
        windows=windows,
        roi_results=roi_results,
        authority_roi_ids=authority_roi_ids,
    )
    status, missing_reason = _observability_status(
        visual_summary=visual_summary,
        rows=rows,
        authority_roi_ids=authority_roi_ids,
        observed_rows=window_coverage["observed_rows"],
    )
    return {
        "schema_version": "self_mirror_test_observability.v0",
        "test_observability": "self_mirror_metric",
        "observability_surface_status": status,
        "capture_surface_kind": _capture_surface_kind(
            visual_summary, capture_target_identity
        ),
        "browser_process_kind": str(capture_target_identity.get("browser_process_kind", "")),
        "same_page_or_target": capture_target_identity.get("same_page_or_target"),
        "proof_ceiling": _proof_ceiling(visual_summary, capture_target_identity),
        "authority_roi_ids": authority_roi_ids,
        "guard_roi_ids": guard_roi_ids,
        "window_coverage": window_coverage,
        "diagnostic_artifact": _diagnostic_artifact_summary(visual_summary),
        "missing_surface_reason": missing_reason,
        "visual_failure_reason_codes": _visual_failure_reason_codes(
            reason_code=reason_code,
            motion_diagnostics=motion_diagnostics,
            surface_status=status,
        ),
        "does_not_prove": NON_CLAIMS,
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_video_included": False,
        "local_path_included": False,
        "provider_payload_included": False,
        "home_control_or_device_state_included": False,
    }


def _authority_roi_ids(roi_results: dict[str, dict[str, Any]]) -> list[str]:
    return sorted(
        roi_id
        for roi_id, roi in roi_results.items()
        if bool(roi.get("counts_as_avatar_motion", False))
        and bool(roi.get("expected_for_pass", False))
    )


def _guard_roi_ids(roi_results: dict[str, dict[str, Any]]) -> list[str]:
    return sorted(
        roi_id
        for roi_id, roi in roi_results.items()
        if not bool(roi.get("counts_as_avatar_motion", False))
        and str(roi.get("kind", "")) != "diagnostic"
    )


def _window_coverage(
    *,
    rows: list[dict[str, Any]],
    windows: dict[str, dict[str, int]],
    roi_results: dict[str, dict[str, Any]],
    authority_roi_ids: list[str],
) -> dict[str, Any]:
    window_ids = {window_id for window_id in windows if window_id}
    roi_ids = {roi_id for roi_id in roi_results if roi_id}
    observed_pairs = {
        (str(row.get("roi_id", "")), str(row.get("window_id", "")))
        for row in rows
        if isinstance(row, dict)
        if row.get("roi_id") and row.get("window_id")
    }
    expected_pairs = {
        (roi_id, window_id)
        for roi_id in roi_ids
        for window_id in window_ids
    }
    active_sample_count = sum(
        1
        for row in rows
        if isinstance(row, dict)
        if str(row.get("window_id", "")) == "active"
        and str(row.get("roi_id", "")) in authority_roi_ids
    )
    return {
        "expected_rows": len(expected_pairs),
        "observed_rows": len(observed_pairs),
        "missing_rows": max(0, len(expected_pairs - observed_pairs)),
        "active_sample_count": active_sample_count,
        "raw_frame_included": False,
        "raw_screenshot_included": False,
    }


def _observability_status(
    *,
    visual_summary: dict[str, Any],
    rows: list[dict[str, Any]],
    authority_roi_ids: list[str],
    observed_rows: int,
) -> tuple[str, str | None]:
    expected_motion = str(visual_summary.get("scenario", {}).get("expected_motion", ""))
    if not rows or observed_rows <= 0:
        return "missing_surface_blocker", "missing-roi-window-metrics"
    if expected_motion != "none" and not authority_roi_ids:
        return "missing_surface_blocker", "missing-authority-roi"
    return "present", None


def _capture_surface_kind(
    visual_summary: dict[str, Any], capture_target_identity: dict[str, Any]
) -> str:
    value = str(capture_target_identity.get("capture_surface_kind", ""))
    if value:
        return value
    proof_layer = str(visual_summary.get("proof_layer", ""))
    if proof_layer == "no_live_runtime":
        return "source_no_live_or_synthetic"
    if visual_summary.get("controlled_chrome_observation"):
        return "controlled_chrome_summary_metric"
    if proof_layer == "browser_runtime":
        return "helper_or_browser_runtime"
    return "unknown"


def _proof_ceiling(
    visual_summary: dict[str, Any], capture_target_identity: dict[str, Any]
) -> str:
    value = str(capture_target_identity.get("proof_ceiling", ""))
    if value:
        return value
    proof_layer = str(visual_summary.get("proof_layer", ""))
    if proof_layer == "no_live_runtime":
        return "source_no_live_or_synthetic_only"
    if visual_summary.get("controlled_chrome_observation"):
        return "controlled_chrome_self_mirror_summary_only_not_physical_display"
    if proof_layer == "browser_runtime":
        return "helper_browser_runtime_only"
    return proof_layer or "unknown"


def _diagnostic_artifact_summary(visual_summary: dict[str, Any]) -> dict[str, Any]:
    artifact_policy = _safe_dict(visual_summary.get("artifact_policy", {}))
    return {
        "included": bool(artifact_policy),
        "support_only": True,
        "raw_media_included": False,
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_video_included": False,
        "local_path_included": False,
        "raw_frames_retained": bool(artifact_policy.get("raw_frames_retained", False)),
        "publication_allowed": False,
    }


def _visual_failure_reason_codes(
    *,
    reason_code: str,
    motion_diagnostics: dict[str, Any],
    surface_status: str,
) -> list[str]:
    if surface_status != "missing_surface_blocker" and reason_code == "visual-pass":
        return []
    codes: list[str] = []
    if surface_status == "missing_surface_blocker":
        codes.append("missing-surface-blocker")
    if reason_code and reason_code != "visual-pass":
        codes.append(reason_code)
    diagnostic_result = str(motion_diagnostics.get("diagnostic_result", ""))
    if diagnostic_result and diagnostic_result != "event-correlated-motion":
        codes.append(diagnostic_result)
    timeline_stage = str(motion_diagnostics.get("timeline_stage", ""))
    if timeline_stage and timeline_stage not in {"runtime-started", "event-timeline-unavailable"}:
        codes.append(timeline_stage)
    return list(dict.fromkeys(codes))


def _motion_diagnostics_summary(summary: dict[str, Any]) -> dict[str, Any]:
    diagnostics = summary.get("motion_diagnostics", {})
    if not isinstance(diagnostics, dict):
        return {}
    return _safe_dict(diagnostics)


def _safe_dict(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    safe: dict[str, Any] = {}
    for key, item in value.items():
        safe_key = _safe_text(key, default="")
        if not safe_key:
            continue
        if safe_key in RAW_PRIVATE_FLAG_KEYS:
            safe[safe_key] = False
            continue
        if isinstance(item, dict):
            safe[safe_key] = _safe_dict(item)
        elif isinstance(item, list):
            safe[safe_key] = [
                _safe_dict(entry) if isinstance(entry, dict) else entry
                for entry in item
                if not _looks_like_path_or_secret(entry)
                and (not isinstance(entry, str) or len(entry) <= 180)
            ]
        elif not _looks_like_path_or_secret(item):
            if isinstance(item, str):
                safe_item = _safe_text(item, default="")
                if safe_item:
                    safe[safe_key] = safe_item
            else:
                safe[safe_key] = item
    return safe


def _safe_text(value: Any, *, default: str = "", max_length: int = 180) -> str:
    if value is None:
        return default
    text = str(value)
    if len(text) > max_length or _looks_like_path_or_secret(text):
        return default
    return text


def _looks_like_path_or_secret(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    lowered = value.lower()
    if "\\" in value or "/" in value:
        return True
    return any(marker in lowered for marker in ("token", "secret", "apikey", "api_key", "bearer "))


def _observed_target(summary: dict[str, Any]) -> str:
    expected = str(summary.get("scenario", {}).get("expected_motion", ""))
    if expected in {"avatar_motion", "broad_avatar_motion", "face_visible_change", "expression_visible_change"}:
        return "avatar"
    if expected == "none":
        return "motion_roi"
    return "projection_visual"


def _target_for_roi(roi_result: dict[str, Any]) -> str:
    if bool(roi_result.get("counts_as_avatar_motion", False)):
        return "avatar"
    return "projection_visual"


def _evidence_layer(proof_layer: str) -> str:
    if proof_layer == "no_live_runtime":
        return "synthetic-method-proof"
    if proof_layer == "browser_runtime":
        return "browser-runtime-roi-proof"
    return proof_layer


def _result_status(reason_code: str) -> str:
    if reason_code == "visual-pass":
        return "pass"
    if reason_code in {"runtime-not-joined", "capture-not-ready"}:
        return "blocked"
    if reason_code in {"visual-pretrigger-motion", "guard-only-motion", "did-not-settle"}:
        return "partial"
    return "fail"


def _metric_confidence(movement_score: float, threshold: float, sample_count: int) -> float:
    if sample_count <= 0:
        return 0.0
    if threshold <= 0:
        return 0.5
    margin = max(0.0, min(1.0, movement_score / threshold))
    sample_support = min(1.0, sample_count / 3.0)
    return round(min(1.0, 0.25 + 0.55 * margin + 0.20 * sample_support), 3)


def _summary_confidence(visual_summary: dict[str, Any]) -> float:
    values = [
        float(row.get("confidence", 0.0))
        for row in visual_summary.get("roi_results", [])
        if isinstance(row, dict)
    ]
    if values and max(values) > 0.0:
        return round(max(0.0, min(1.0, max(values))), 3)

    threshold = float(visual_summary.get("thresholds", {}).get("active_motion_min_score", 0.0))
    peak_values = [
        float(row.get("active_peak_motion_score", 0.0))
        for row in visual_summary.get("roi_results", [])
        if isinstance(row, dict) and bool(row.get("expected_for_pass", False))
    ]
    if not peak_values:
        peak_values = [
            float(row.get("active_peak_motion_score", 0.0))
            for row in visual_summary.get("roi_results", [])
            if isinstance(row, dict)
        ]
    return _metric_confidence(max(peak_values, default=0.0), threshold, len(peak_values))


def _observation_policy(activation_sampling: str, evidence_export: str) -> dict[str, Any]:
    activation_policies = {
        "disabled": {
            "timing": "no_capture_or_analyze",
        },
        "event_driven": {
            "timing": "after_motion_expression_or_display_event",
        },
        "periodic_lightweight": {
            "timing": "periodic_health_or_freshness_check",
        },
        "continuous_monitor": {
            "timing": "continuous_or_near_continuous_observation",
        },
    }
    export_policies = {
        "status_only": {
            "depth": "status_and_freshness_only",
            "shareable_output": "status_only",
            "timeline_export_expected": False,
            "local_only_diagnostics": False,
        },
        "metric_summary": {
            "depth": "machine_readable_metric_summary",
            "shareable_output": "self_mirror_metric_summary.v0",
            "timeline_export_expected": False,
            "local_only_diagnostics": False,
        },
        "verification_capture": {
            "depth": "summary_plus_redacted_timeline_views",
            "shareable_output": "summary_plus_csv_html_or_jsonl_supporting_views",
            "timeline_export_expected": True,
            "local_only_diagnostics": False,
        },
        "diagnostic_local": {
            "depth": "extra_local_diagnostics_when_explicitly_enabled",
            "shareable_output": "local_only_unless_redacted_and_reviewed",
            "timeline_export_expected": True,
            "local_only_diagnostics": True,
        },
    }
    activation = activation_policies.get(activation_sampling, activation_policies["event_driven"])
    export = export_policies.get(evidence_export, export_policies["verification_capture"])
    return {
        "activation_sampling": activation_sampling,
        "evidence_export": evidence_export,
        "timing": activation["timing"],
        "depth": export["depth"],
        "shareable_output": export["shareable_output"],
        "timeline_export_expected": export["timeline_export_expected"],
        "local_only_diagnostics": export["local_only_diagnostics"],
        "verification_capture_is_completion_proof": False,
    }


def _consumer_retry_policy(observation_ref: str) -> dict[str, Any]:
    return {
        "self_mirror_is_command_channel": False,
        "self_mirror_retry_authority": False,
        "self_mirror_observation_ref": observation_ref,
        "retry_policy_kind": "consumer_config_reference",
        "retry_limit_default": 2,
        "retry_limit_configurable": True,
        "retry_policy_source": (
            "THOUGHT_CORE_SELF_MIRROR_RETRY_LIMIT|"
            "thought_core.self_mirror_retry.limit|"
            "selfMirrorRetryPolicyState"
        ),
        "retry_execution_owner": "thought_core_or_output_owner",
        "external_side_effect_auto_retry_allowed": False,
        "applies_to_side_effect_class": "internal_self_display_only",
        "failure_escalation_policy": {
            "self_mirror_escalation_authority": False,
            "one_off_failure_route": "trace_only",
            "candidate_routes": ["memory_core_candidate", "issue_ticket_candidate"],
            "candidate_when": [
                "repeated_failure",
                "important_or_safety_tag",
                "review_blocker",
                "user_reported",
                "likely_implementation_gap",
                "configured_limit_exhausted",
            ],
        },
        "required_trace_fields": [
            "retry_count",
            "retry_limit",
            "retry_policy_source",
            "retry_reason",
            "self_mirror_observation_ref",
            "action_kind",
            "side_effect_class",
            "final_status",
            "gave_up_reason",
            "failure_pattern",
        ],
    }


def _observed_issue(reason_code: str) -> str:
    if reason_code == "visual-pass":
        return ""
    return reason_code


def _safe_slug(value: Any) -> str:
    text = str(value).strip().lower()
    if len(text) > 180 or _looks_like_path_or_secret(text):
        return "redacted"
    return "".join(char if char.isalnum() else "_" for char in text).strip("_") or "unknown"
