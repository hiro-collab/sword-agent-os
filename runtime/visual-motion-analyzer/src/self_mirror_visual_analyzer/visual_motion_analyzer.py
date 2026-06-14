from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import cv2
import numpy as np

from .summary import build_self_mirror_metric_summary


AVATAR_PASS_LABEL = "visual-motion-detected"
AVATAR_NOT_REQUIRED_LABEL = "avatar-motion-not-required"
GUARD_EXCLUDED_LABEL = "guard-ui-motion-excluded"
MISSING_MOTION_LABEL = "visual-missing-motion"
PRETRIGGER_LABEL = "visual-pretrigger-motion"
SETTLE_JITTER_LABEL = "did-not-settle"
VISUAL_PASS = "visual-pass"
GUARD_ONLY_LABEL = "guard-only-motion"
RUNTIME_NOT_JOINED_LABEL = "runtime-not-joined"
CAPTURE_NOT_READY_LABEL = "capture-not-ready"
ROI_OUT_OF_FRAME_LABEL = "roi-out-of-frame"
THRESHOLD_TOO_STRICT_LABEL = "threshold-too-strict"
UI_ONLY_LABEL = GUARD_ONLY_LABEL
LATE_VISIBLE_MOTION_LABEL = "late-visible-motion"
MOTION_OUTSIDE_EXPECTED_ROI_LABEL = "motion-outside-expected-roi"
IDLE_ONLY_MOTION_LABEL = "idle-only-motion"
NO_VISIBLE_MOTION_LABEL = "no-visible-motion"
RUNTIME_STARTED_NO_VISIBLE_MOTION_LABEL = "runtime-started-no-visible-motion"
RUNTIME_STARTED_NO_FRAME_APPLIED_LABEL = "runtime-started-but-no-frame-applied"
FRAME_APPLIED_PIXEL_STATIC_LABEL = "frame-applied-but-pixel-static"
DELAYED_VISIBLE_CHANGE_LABEL = "delayed-visible-change"
PRETRIGGER_CONTAMINATION_LABEL = "pretrigger-contamination"
ROI_THRESHOLD_MISS_LABEL = "roi-threshold-miss"
WRONG_TARGET_OR_SURFACE_MISMATCH_LABEL = "wrong-target-or-surface-mismatch"
SAFE_REDACTED_SOURCE_REF_PATTERN = re.compile(r"^redacted_[a-z0-9_.:-]+$")
SOURCE_REF_KINDS = {
    "local_frame_sequence",
    "local_video_file",
    "browser_frame_provider",
    "synthetic_test_frames",
    "controlled_chrome_metric_summary",
    "projection_visual_roi_metrics",
}
ACTIVATION_SAMPLING_MODES = {
    "disabled",
    "event_driven",
    "periodic_lightweight",
    "continuous_monitor",
}
EVIDENCE_EXPORT_LEVELS = {
    "status_only",
    "metric_summary",
    "verification_capture",
    "diagnostic_local",
}
EVENT_ANCHORS = {
    "user_request": "user_request_at_ms",
    "motion_requested": "motion_requested_at_ms",
    "bridge_dispatched": "bridge_dispatched_at_ms",
    "runtime_accepted": "runtime_accepted_at_ms",
    "runtime_started": "runtime_started_at_ms",
    "runtime_result": "runtime_result_at_ms",
    "driver_applied": "driver_applied_at_ms",
    "frame_applied": "frame_applied_at_ms",
    "visual_commit": "visual_commit_at_ms",
    "capture_started": "capture_started_at_ms",
    "analysis_started": "analysis_started_at_ms",
}


@dataclass(frozen=True)
class Window:
    window_id: str
    start_ms: int
    end_ms: int


@dataclass(frozen=True)
class Roi:
    roi_id: str
    kind: str
    counts_as_avatar_motion: bool
    expected_for_pass: bool
    rect_norm: dict[str, float]
    out_of_frame: bool


def analyze_frames(
    frames_bgr: list[np.ndarray],
    *,
    analysis_run_id: str,
    scenario_id: str,
    motion_event_id: str,
    stimulus_instance_id: str,
    driver_result_id: str,
    sample_rate_fps: float,
    windows: list[dict[str, Any]],
    rois: list[dict[str, Any]],
    thresholds: dict[str, Any] | None = None,
    source_ref_id: str = "redacted_local_source",
    source_ref_kind: str = "local_frame_sequence",
    proof_layer: str = "no_live_runtime",
    scenario_key: str = "",
    scenario_label: str = "",
    expected_motion: str = "avatar_motion",
    runtime_join_required: bool = False,
    runtime_join: dict[str, Any] | None = None,
    event_timeline: dict[str, Any] | None = None,
    projection_visual_diagnostics: dict[str, Any] | None = None,
    capture_target_identity: dict[str, Any] | None = None,
    stimulus_id: str = "",
    capture_ready: dict[str, Any] | None = None,
    raw_frames_retained: bool = False,
    activation_sampling: str = "event_driven",
    evidence_export: str = "verification_capture",
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not frames_bgr:
        raise ValueError("frames_bgr must contain at least one frame")
    if sample_rate_fps <= 0:
        raise ValueError("sample_rate_fps must be greater than 0")

    parsed_windows = [_parse_window(window) for window in windows]
    parsed_rois = [_parse_roi(roi) for roi in rois]
    limits = {
        "active_motion_min_score": 0.12,
        "settle_motion_max_score": 0.05,
        "min_consecutive_samples": 2,
        "threshold_too_strict_ratio": 0.75,
    }
    if thresholds:
        limits.update(thresholds)

    rows: list[dict[str, Any]] = []
    baseline = frames_bgr[0]
    previous = frames_bgr[0]
    for frame_index, frame in enumerate(frames_bgr):
        time_ms = int(round(frame_index * 1000.0 / sample_rate_fps))
        window_id = _window_id_at(time_ms, parsed_windows)
        if frame_index == 0:
            previous = frame
            continue
        for roi in parsed_rois:
            rows.append(
                _measure_roi(
                    frame,
                    previous,
                    baseline,
                    roi=roi,
                    analysis_run_id=analysis_run_id,
                    time_ms=time_ms,
                    window_id=window_id,
                )
            )
        previous = frame

    roi_results = _summarize_rois(rows, parsed_rois, limits)
    label_by_roi = {row["roi_id"]: row["pass_label"] for row in roi_results}
    for row in rows:
        row["pass_label"] = label_by_roi.get(str(row["roi_id"]), "")
    safe_projection_visual_diagnostics = _safe_projection_visual_diagnostics(projection_visual_diagnostics)
    result = _overall_result(
        roi_results,
        limits,
        scenario_id=scenario_id,
        scenario_key=scenario_key or scenario_id,
        expected_motion=expected_motion,
        runtime_join_required=runtime_join_required,
        runtime_join=runtime_join,
        projection_visual_diagnostics=safe_projection_visual_diagnostics,
        capture_ready=capture_ready,
        proof_layer=proof_layer,
    )
    normalized_event_timeline = _normalized_event_timeline(
        event_timeline, safe_projection_visual_diagnostics
    )
    safe_capture_target_identity = _safe_capture_target_identity(capture_target_identity)
    motion_diagnostics = _motion_diagnostics(
        rows=rows,
        roi_results=roi_results,
        thresholds=limits,
        runtime_join=runtime_join,
        event_timeline=normalized_event_timeline,
        projection_visual_diagnostics=safe_projection_visual_diagnostics,
    )
    evaluation_window_ms = max((window.end_ms for window in parsed_windows), default=0)
    summary = {
        "schema_version": "visual_motion_analysis.v0",
        "analysis_run_id": analysis_run_id,
        "scenario_id": scenario_id,
        "scenario": {
            "scenario_key": scenario_key or scenario_id,
            "label": scenario_label or scenario_id,
            "expected_motion": expected_motion,
            "runtime_join_required": bool(runtime_join_required),
        },
        "proof_layer": proof_layer,
        "activation_sampling": _safe_activation_sampling(activation_sampling),
        "evidence_export": _safe_evidence_export(evidence_export),
        "motion_event_id": motion_event_id,
        "stimulus_id": str(stimulus_id or (runtime_join or {}).get("stimulus_id", "")),
        "stimulus_instance_id": stimulus_instance_id,
        "driver_result_id": driver_result_id,
        "mixer_tick_ids": [],
        "source_ref": {
            "kind": _safe_source_ref_kind(source_ref_kind),
            "source_ref_id": _safe_source_ref_id(source_ref_id),
            "raw_source_shared": False,
        },
        "sampling": {
            "sample_rate_fps": sample_rate_fps,
            "evaluation_window_ms": evaluation_window_ms,
            "frame_count": len(frames_bgr),
        },
        "windows": [
            {"window_id": window.window_id, "start_ms": window.start_ms, "end_ms": window.end_ms}
            for window in parsed_windows
        ],
        "roi_config": {
            "viewport": {"width": int(frames_bgr[0].shape[1]), "height": int(frames_bgr[0].shape[0])},
            "rois": [
                {
                    "roi_id": roi.roi_id,
                    "kind": roi.kind,
                    "counts_as_avatar_motion": roi.counts_as_avatar_motion,
                    "expected_for_pass": roi.expected_for_pass,
                    "rect_norm": roi.rect_norm,
                    "out_of_frame": roi.out_of_frame,
                }
                for roi in parsed_rois
            ],
        },
        "thresholds": {
            "active_motion_min_score": float(limits["active_motion_min_score"]),
            "settle_motion_max_score": float(limits["settle_motion_max_score"]),
            "min_consecutive_samples": int(limits["min_consecutive_samples"]),
            "threshold_too_strict_ratio": float(limits["threshold_too_strict_ratio"]),
        },
        "result": result,
        "classification": {
            "reason_code": result,
            "next_action": _next_action_for_result(result),
        },
        "capture": {
            "capture_ready": _capture_is_ready(capture_ready),
            "self_mirror_ready": _safe_summary_object(capture_ready),
            "target_identity": safe_capture_target_identity,
        },
        "capture_target_identity": safe_capture_target_identity,
        "runtime_join": _safe_summary_object(runtime_join),
        "event_timeline": _safe_event_timeline(normalized_event_timeline),
        "projection_visual_diagnostics": safe_projection_visual_diagnostics,
        "motion_diagnostics": motion_diagnostics,
        "roi_results": roi_results,
        "artifact_policy": {
            "raw_frames_shared": False,
            "raw_paths_shared": False,
            "chart_shared": False,
            "raw_frames_retained": bool(raw_frames_retained),
            "cleanup_note_required": True,
        },
        "redaction": {
            "redaction_status": "summary_only",
            "shareability_class": "review_packet",
            "public_safe": False,
        },
        "safety": {
            "raw_prompt_shared": False,
            "raw_transcript_shared": False,
            "raw_log_shared": False,
            "raw_media_shared": False,
            "raw_path_shared": False,
            "raw_asset_filename_shared": False,
            "provider_payload_shared": False,
            "private_endpoint_shared": False,
            "home_assistant_route_retained": False,
        },
    }
    return summary, rows


def analyze_config(config: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    source_ref = config.get("source_ref", {})
    sampling = config.get("sampling", {})
    scenario = dict(config.get("scenario", {}))
    sample_rate_fps = float(sampling.get("sample_rate_fps", config.get("sample_rate_fps", 8)))
    windows = list(config["windows"])
    rois = list(config["rois"])
    if "controlled_chrome_observation" in config:
        return _analyze_controlled_chrome_observation(
            config=config,
            source_ref=source_ref,
            sampling=sampling,
            scenario=scenario,
            sample_rate_fps=sample_rate_fps,
            windows=windows,
            rois=rois,
        )
    if "synthetic_fixture" in config:
        frames = _generate_synthetic_fixture_frames(
            dict(config["synthetic_fixture"]),
            windows=windows,
            rois=rois,
            sample_rate_fps=sample_rate_fps,
        )
        source_ref_kind = str(source_ref.get("kind", "synthetic_test_frames"))
    else:
        frame_paths = [Path(path) for path in config.get("frame_paths", [])]
        if not frame_paths:
            raise ValueError("config.frame_paths must contain local frame paths or synthetic_fixture")
        frames = [_read_frame(path) for path in frame_paths]
        source_ref_kind = str(source_ref.get("kind", "local_frame_sequence"))

    return analyze_frames(
        frames,
        analysis_run_id=str(config["analysis_run_id"]),
        scenario_id=str(config["scenario_id"]),
        motion_event_id=str(config["motion_event_id"]),
        stimulus_instance_id=str(config["stimulus_instance_id"]),
        driver_result_id=str(config["driver_result_id"]),
        sample_rate_fps=sample_rate_fps,
        windows=windows,
        rois=rois,
        thresholds=dict(config.get("thresholds", {})),
        source_ref_id=str(source_ref.get("source_ref_id", "redacted_local_source")),
        source_ref_kind=source_ref_kind,
        proof_layer=str(config.get("proof_layer", "no_live_runtime")),
        scenario_key=str(scenario.get("scenario_key", config.get("scenario_key", ""))),
        scenario_label=str(scenario.get("label", config.get("scenario_label", ""))),
        expected_motion=str(scenario.get("expected_motion", config.get("expected_motion", "avatar_motion"))),
        runtime_join_required=bool(
            scenario.get("runtime_join_required", config.get("runtime_join_required", False))
        ),
        runtime_join=dict(config.get("runtime_join", {})) if config.get("runtime_join") else None,
        event_timeline=dict(config.get("event_timeline", {})) if config.get("event_timeline") else None,
        projection_visual_diagnostics=(
            dict(config.get("projection_visual_diagnostics", {}))
            if config.get("projection_visual_diagnostics")
            else None
        ),
        capture_target_identity=(
            dict(config.get("target_identity", config.get("capture_target_identity", {})))
            if config.get("target_identity") or config.get("capture_target_identity")
            else None
        ),
        stimulus_id=str(config.get("stimulus_id", "")),
        capture_ready=dict(config.get("capture_ready", {})) if config.get("capture_ready") else None,
        raw_frames_retained=bool(config.get("raw_frames_retained", False)),
        activation_sampling=str(
            config.get("activation_sampling", config.get("self_mirror_activation_sampling", "event_driven"))
        ),
        evidence_export=str(
            config.get("evidence_export", config.get("self_mirror_evidence_export", "verification_capture"))
        ),
    )


def _analyze_controlled_chrome_observation(
    *,
    config: dict[str, Any],
    source_ref: dict[str, Any],
    sampling: dict[str, Any],
    scenario: dict[str, Any],
    sample_rate_fps: float,
    windows: list[dict[str, Any]],
    rois: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    observation = dict(config["controlled_chrome_observation"])
    _reject_raw_evidence_flags(observation)
    if sample_rate_fps <= 0:
        raise ValueError("sample_rate_fps must be greater than 0")

    parsed_windows = [_parse_window(window) for window in windows]
    parsed_rois = [_parse_roi(roi) for roi in rois]
    limits = {
        "active_motion_min_score": 0.12,
        "settle_motion_max_score": 0.05,
        "min_consecutive_samples": 2,
        "threshold_too_strict_ratio": 0.75,
    }
    if config.get("thresholds"):
        limits.update(dict(config["thresholds"]))

    rows = _rows_from_controlled_chrome_window_metrics(
        observation.get("roi_window_metrics", []),
        analysis_run_id=str(config["analysis_run_id"]),
        windows=parsed_windows,
        rois=parsed_rois,
    )
    if not rows:
        raise ValueError(
            "controlled_chrome_observation.roi_window_metrics must contain summary-only ROI/window metrics"
        )

    roi_results = _summarize_rois(rows, parsed_rois, limits)
    label_by_roi = {row["roi_id"]: row["pass_label"] for row in roi_results}
    for row in rows:
        row["pass_label"] = label_by_roi.get(str(row["roi_id"]), "")

    target_identity = _safe_capture_target_identity(observation.get("target_identity", {}))
    capture_ready = dict(config.get("capture_ready", observation.get("capture_ready", {"skipped": True})))
    projection_visual_diagnostics = _controlled_chrome_projection_visual_diagnostics(
        config.get("projection_visual_diagnostics"),
        observation=observation,
        target_identity=target_identity,
    )
    safe_projection_visual_diagnostics = _safe_projection_visual_diagnostics(
        projection_visual_diagnostics
    )
    runtime_join = dict(config.get("runtime_join", observation.get("runtime_join", {})))
    event_timeline = dict(config.get("event_timeline", observation.get("event_timeline", {})))
    normalized_event_timeline = _normalized_event_timeline(
        event_timeline, safe_projection_visual_diagnostics
    )
    result = _overall_result(
        roi_results,
        limits,
        scenario_id=str(config["scenario_id"]),
        scenario_key=str(scenario.get("scenario_key", config.get("scenario_key", ""))),
        expected_motion=str(scenario.get("expected_motion", config.get("expected_motion", "avatar_motion"))),
        runtime_join_required=bool(
            scenario.get("runtime_join_required", config.get("runtime_join_required", False))
        ),
        runtime_join=runtime_join,
        projection_visual_diagnostics=safe_projection_visual_diagnostics,
        capture_ready=capture_ready,
        proof_layer=str(config.get("proof_layer", "visible_motion")),
    )
    motion_diagnostics = _motion_diagnostics(
        rows=rows,
        roi_results=roi_results,
        thresholds=limits,
        runtime_join=runtime_join,
        event_timeline=normalized_event_timeline,
        projection_visual_diagnostics=safe_projection_visual_diagnostics,
    )
    evaluation_window_ms = max((window.end_ms for window in parsed_windows), default=0)
    viewport = dict(observation.get("viewport", {}))
    viewport_width = int(viewport.get("width", 0) or 0)
    viewport_height = int(viewport.get("height", 0) or 0)
    summary = {
        "schema_version": "visual_motion_analysis.v0",
        "analysis_run_id": str(config["analysis_run_id"]),
        "scenario_id": str(config["scenario_id"]),
        "scenario": {
            "scenario_key": str(scenario.get("scenario_key", config.get("scenario_key", config["scenario_id"]))),
            "label": str(scenario.get("label", config.get("scenario_label", config["scenario_id"]))),
            "expected_motion": str(
                scenario.get("expected_motion", config.get("expected_motion", "avatar_motion"))
            ),
            "runtime_join_required": bool(
                scenario.get("runtime_join_required", config.get("runtime_join_required", False))
            ),
        },
        "proof_layer": str(config.get("proof_layer", "visible_motion")),
        "activation_sampling": _safe_activation_sampling(
            str(config.get("activation_sampling", config.get("self_mirror_activation_sampling", "event_driven")))
        ),
        "evidence_export": _safe_evidence_export(
            str(config.get("evidence_export", config.get("self_mirror_evidence_export", "metric_summary")))
        ),
        "motion_event_id": str(config["motion_event_id"]),
        "stimulus_id": str(runtime_join.get("stimulus_id", config.get("stimulus_id", ""))),
        "stimulus_instance_id": str(config["stimulus_instance_id"]),
        "driver_result_id": str(config["driver_result_id"]),
        "mixer_tick_ids": [],
        "source_ref": {
            "kind": _safe_source_ref_kind(str(source_ref.get("kind", "controlled_chrome_metric_summary"))),
            "source_ref_id": _safe_source_ref_id(str(source_ref.get("source_ref_id", "redacted_controlled_chrome"))),
            "raw_source_shared": False,
        },
        "sampling": {
            "sample_rate_fps": sample_rate_fps,
            "evaluation_window_ms": evaluation_window_ms,
            "frame_count": _controlled_chrome_sample_count(rows),
            "source": "summary_only_controlled_chrome_roi_metrics",
        },
        "windows": [
            {"window_id": window.window_id, "start_ms": window.start_ms, "end_ms": window.end_ms}
            for window in parsed_windows
        ],
        "roi_config": {
            "viewport": {"width": viewport_width, "height": viewport_height},
            "rois": [
                {
                    "roi_id": roi.roi_id,
                    "kind": roi.kind,
                    "counts_as_avatar_motion": roi.counts_as_avatar_motion,
                    "expected_for_pass": roi.expected_for_pass,
                    "rect_norm": roi.rect_norm,
                    "out_of_frame": roi.out_of_frame,
                }
                for roi in parsed_rois
            ],
        },
        "thresholds": {
            "active_motion_min_score": float(limits["active_motion_min_score"]),
            "settle_motion_max_score": float(limits["settle_motion_max_score"]),
            "min_consecutive_samples": int(limits["min_consecutive_samples"]),
            "threshold_too_strict_ratio": float(limits["threshold_too_strict_ratio"]),
        },
        "result": result,
        "classification": {
            "reason_code": result,
            "next_action": _next_action_for_result(result),
        },
        "capture": {
            "capture_ready": _capture_is_ready(capture_ready),
            "self_mirror_ready": _safe_summary_object(capture_ready),
            "target_identity": target_identity,
        },
        "capture_target_identity": target_identity,
        "controlled_chrome_observation": _safe_controlled_chrome_observation_summary(
            observation,
            target_identity=target_identity,
        ),
        "runtime_join": _safe_summary_object(runtime_join),
        "event_timeline": _safe_event_timeline(normalized_event_timeline),
        "projection_visual_diagnostics": safe_projection_visual_diagnostics,
        "motion_diagnostics": motion_diagnostics,
        "roi_results": roi_results,
        "artifact_policy": {
            "raw_frames_shared": False,
            "raw_paths_shared": False,
            "chart_shared": False,
            "raw_frames_retained": False,
            "cleanup_note_required": True,
        },
        "redaction": {
            "redaction_status": "summary_only",
            "shareability_class": "review_packet",
            "public_safe": False,
        },
        "safety": {
            "raw_prompt_shared": False,
            "raw_transcript_shared": False,
            "raw_log_shared": False,
            "raw_media_shared": False,
            "raw_path_shared": False,
            "raw_asset_filename_shared": False,
            "provider_payload_shared": False,
            "private_endpoint_shared": False,
            "home_assistant_route_retained": False,
        },
    }
    return summary, rows


def write_outputs(
    summary: dict[str, Any], rows: list[dict[str, Any]], output_dir: Path
) -> tuple[Path, Path, Path, Path, Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    self_mirror_summary_path = output_dir / "self_mirror_metric_summary.json"
    summary_path = output_dir / "visual_motion_summary.json"
    csv_path = output_dir / "visual_motion_roi_timeseries.csv"
    chart_path = output_dir / "visual_motion_chart.html"
    result_path = output_dir / "result.md"
    manifest_path = output_dir / "manifest.json"
    self_mirror_summary = build_self_mirror_metric_summary(summary, rows)
    self_mirror_summary_path.write_text(
        json.dumps(self_mirror_summary, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    fieldnames = [
        "analysis_run_id",
        "time_ms",
        "window_id",
        "roi_id",
        "roi_kind",
        "counts_as_avatar_motion",
        "changed_pixel_ratio",
        "optical_flow_mean",
        "optical_flow_p95",
        "bbox_delta",
        "centroid_delta",
        "ssim_to_baseline",
        "motion_score",
        "pass_label",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})
    _write_chart_html(summary, rows, chart_path)
    _write_result_guide(summary, result_path)
    _write_manifest(summary, manifest_path)
    return self_mirror_summary_path, summary_path, csv_path, chart_path, result_path, manifest_path


def _write_chart_html(summary: dict[str, Any], rows: list[dict[str, Any]], chart_path: Path) -> None:
    width = 1100
    height = 520
    left = 70
    right = 240
    top = 32
    bottom = 56
    plot_width = width - left - right
    plot_height = height - top - bottom
    max_time = max([int(row["time_ms"]) for row in rows], default=1)
    max_time = max(max_time, int(summary.get("sampling", {}).get("evaluation_window_ms", 1)))
    active_threshold = float(summary.get("thresholds", {}).get("active_motion_min_score", 0.0))
    settle_threshold = float(summary.get("thresholds", {}).get("settle_motion_max_score", 0.0))

    def x_for(time_ms: float) -> float:
        return left + (time_ms / max_time) * plot_width

    def y_for(score: float) -> float:
        return top + (1.0 - max(0.0, min(1.0, score))) * plot_height

    window_colors = {
        "pretrigger": "#f4f1e8",
        "active": "#e7f1fb",
        "release": "#eef5e8",
        "settle": "#f6ebef",
    }
    band_svg: list[str] = []
    label_svg: list[str] = []
    for window in summary.get("windows", []):
        start = float(window.get("start_ms", 0))
        end = float(window.get("end_ms", start))
        x0 = x_for(start)
        x1 = x_for(end)
        color = window_colors.get(str(window.get("window_id")), "#f3f4f6")
        band_svg.append(
            f'<rect x="{x0:.2f}" y="{top}" width="{max(0.0, x1 - x0):.2f}" '
            f'height="{plot_height}" fill="{color}" opacity="0.78" />'
        )
        label_svg.append(
            f'<text x="{(x0 + x1) / 2:.2f}" y="{top + 18}" text-anchor="middle" '
            f'class="band-label">{html.escape(str(window.get("window_id", "")))}</text>'
        )

    roi_meta = {
        str(roi.get("roi_id")): roi
        for roi in summary.get("roi_config", {}).get("rois", [])
        if isinstance(roi, dict)
    }
    roi_ids = sorted({str(row["roi_id"]) for row in rows})
    avatar_palette = ["#0f6b7a", "#21808d", "#4a9a88", "#6f7fc8", "#9467bd"]
    guard_palette = ["#c26a2e", "#8f6a2f", "#aa4f5a", "#6f6f6f", "#9a7a23"]
    avatar_index = 0
    guard_index = 0
    line_svg: list[str] = []
    legend_svg: list[str] = []
    for legend_index, roi_id in enumerate(roi_ids):
        meta = roi_meta.get(roi_id, {})
        is_avatar = bool(meta.get("counts_as_avatar_motion"))
        if is_avatar:
            color = avatar_palette[avatar_index % len(avatar_palette)]
            avatar_index += 1
        else:
            color = guard_palette[guard_index % len(guard_palette)]
            guard_index += 1
        points = [
            f'{x_for(float(row["time_ms"])):.2f},{y_for(float(row["motion_score"])):.2f}'
            for row in sorted((row for row in rows if str(row["roi_id"]) == roi_id), key=lambda item: int(item["time_ms"]))
        ]
        if points:
            line_svg.append(
                f'<polyline points="{" ".join(points)}" fill="none" stroke="{color}" '
                'stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round" />'
            )
        legend_y = top + 22 + legend_index * 22
        legend_kind = "avatar" if is_avatar else "guard"
        legend_svg.append(
            f'<g><line x1="{width - right + 24}" y1="{legend_y}" x2="{width - right + 52}" '
            f'y2="{legend_y}" stroke="{color}" stroke-width="3" />'
            f'<text x="{width - right + 60}" y="{legend_y + 4}" class="legend">'
            f'{html.escape(roi_id)} ({legend_kind})</text></g>'
        )

    threshold_svg = []
    for label, value, color, dash in (
        ("active threshold", active_threshold, "#b3261e", ""),
        ("settle threshold", settle_threshold, "#5f6368", " stroke-dasharray=\"5 4\""),
    ):
        y = y_for(value)
        threshold_svg.append(
            f'<line x1="{left}" y1="{y:.2f}" x2="{left + plot_width}" y2="{y:.2f}" '
            f'stroke="{color}" stroke-width="1.4"{dash} />'
            f'<text x="{left + plot_width + 10}" y="{y + 4:.2f}" class="threshold">'
            f'{html.escape(label)} {value:.3f}</text>'
        )

    result = html.escape(str(summary.get("result", "unknown")))
    scenario = html.escape(str(summary.get("scenario", {}).get("label", summary.get("scenario_id", ""))))
    body = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Visual Motion Chart</title>
  <style>
    body {{ margin: 0; padding: 24px; font-family: Segoe UI, Arial, sans-serif; color: #1f2933; background: #fbfcfd; }}
    h1 {{ font-size: 20px; margin: 0 0 4px; }}
    .meta {{ font-size: 13px; margin: 0 0 18px; color: #4b5563; }}
    svg {{ background: #fff; border: 1px solid #d5dbe3; border-radius: 6px; }}
    .axis {{ stroke: #2f3a45; stroke-width: 1; }}
    .band-label {{ font-size: 11px; fill: #4b5563; }}
    .legend, .threshold, .tick {{ font-size: 12px; fill: #2f3a45; }}
  </style>
</head>
<body>
  <h1>Visual Motion ROI Timeseries</h1>
  <p class="meta">Scenario: {scenario} | Result: {result} | Raw paths shared: false</p>
  <svg width="{width}" height="{height}" role="img" aria-label="ROI motion score timeseries">
    {"".join(band_svg)}
    {"".join(label_svg)}
    <line x1="{left}" y1="{top}" x2="{left}" y2="{top + plot_height}" class="axis" />
    <line x1="{left}" y1="{top + plot_height}" x2="{left + plot_width}" y2="{top + plot_height}" class="axis" />
    <text x="{left - 48}" y="{top + 5}" class="tick">1.0</text>
    <text x="{left - 48}" y="{top + plot_height + 4}" class="tick">0.0</text>
    <text x="{left + plot_width / 2:.2f}" y="{height - 18}" text-anchor="middle" class="tick">time ms</text>
    <text x="18" y="{top + plot_height / 2:.2f}" transform="rotate(-90 18,{top + plot_height / 2:.2f})" text-anchor="middle" class="tick">motion_score</text>
    {"".join(threshold_svg)}
    {"".join(line_svg)}
    {"".join(legend_svg)}
  </svg>
</body>
</html>
"""
    chart_path.write_text(body, encoding="utf-8")


def _write_result_guide(summary: dict[str, Any], result_path: Path) -> None:
    result = str(summary.get("result", "unknown"))
    passed_rois = [
        str(row["roi_id"])
        for row in summary.get("roi_results", [])
        if row.get("pass_label") == AVATAR_PASS_LABEL
    ]
    failed_rois = [
        str(row["roi_id"])
        for row in summary.get("roi_results", [])
        if row.get("pass_label")
        in {MISSING_MOTION_LABEL, PRETRIGGER_LABEL, SETTLE_JITTER_LABEL, ROI_OUT_OF_FRAME_LABEL}
    ]
    guard_rois = [
        str(row["roi_id"])
        for row in summary.get("roi_results", [])
        if not bool(row.get("counts_as_avatar_motion"))
    ]
    observed_rois = [str(row["roi_id"]) for row in summary.get("roi_results", [])]
    raw_retained = bool(summary.get("artifact_policy", {}).get("raw_frames_retained", False))
    expected_motion = str(summary.get("scenario", {}).get("expected_motion", "avatar_motion"))
    active_threshold = float(summary.get("thresholds", {}).get("active_motion_min_score", 0.0))
    guard_motion = _guard_motion_sentence(summary, active_threshold)
    if result == VISUAL_PASS and expected_motion == "none":
        what_passed = "Idle/baseline ROIs stayed below the active motion threshold."
    elif result == VISUAL_PASS:
        what_passed = "Expected avatar ROI motion crossed the active threshold and settled."
    else:
        what_passed = "No visual pass is claimed for this run."

    next_action = _next_action_for_result(result)
    lines = [
        "# Visual Motion Result",
        "",
        f"- Result: `{result}`",
        f"- Proof layer: `{summary.get('proof_layer', 'unknown')}`",
        f"- Scenario: `{summary.get('scenario', {}).get('scenario_key', summary.get('scenario_id', 'unknown'))}`",
        f"- What passed: {what_passed}",
        f"- Fail / known gap: {_failure_sentence(result)}",
        f"- ROI to inspect: `{', '.join(failed_rois or passed_rois or observed_rois or guard_rois)}`",
        f"- Guard ROI motion: {guard_motion}",
        f"- Raw frames retained: {'yes, local-only' if raw_retained else 'no'}",
        f"- Next step: {next_action}",
        "",
        "Non-claim: this package is ROI/time-series evidence only. It does not prove broad RR003 completion, dance, pointing, live camera/device proof, or autonomous Self Mirror judgement.",
    ]
    result_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _guard_motion_sentence(summary: dict[str, Any], threshold: float) -> str:
    guard_hits: list[str] = []
    for row in summary.get("roi_results", []):
        if bool(row.get("counts_as_avatar_motion")):
            continue
        peaks = [
            float(row.get("pretrigger_peak_motion_score", 0.0)),
            float(row.get("active_peak_motion_score", 0.0)),
            float(row.get("release_peak_motion_score", 0.0)),
            float(row.get("settle_peak_motion_score", 0.0)),
        ]
        if max(peaks, default=0.0) >= threshold:
            guard_hits.append(f"{row.get('roi_id')} max={max(peaks):.3f}")
    if not guard_hits:
        return "none"
    return "; ".join(guard_hits) + " (excluded from avatar pass)"


def _write_manifest(summary: dict[str, Any], manifest_path: Path) -> None:
    manifest = {
        "schema_version": "self_mirror_result_package.v0",
        "analysis_run_id": summary.get("analysis_run_id"),
        "scenario_id": summary.get("scenario_id"),
        "scenario": summary.get("scenario", {}),
        "proof_layer": summary.get("proof_layer"),
        "result": summary.get("result"),
        "classification": summary.get("classification", {}),
        "artifacts": {
            "self_mirror_metric_summary": "self_mirror_metric_summary.json",
            "summary": "visual_motion_summary.json",
            "timeseries": "visual_motion_roi_timeseries.csv",
            "chart": "visual_motion_chart.html",
            "result_guide": "result.md",
        },
        "retention": {
            "raw_frames_retained": bool(summary.get("artifact_policy", {}).get("raw_frames_retained", False)),
            "raw_frames_shared": False,
            "raw_paths_shared": False,
        },
        "shareability": {
            "review_packet": True,
            "public_safe": False,
            "raw_media_included": False,
            "local_paths_included": False,
            "tokens_or_secrets_included": False,
        },
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _parse_window(value: dict[str, Any]) -> Window:
    start_ms = int(value["start_ms"])
    end_ms = int(value["end_ms"])
    if end_ms <= start_ms:
        raise ValueError(f"window end_ms must be greater than start_ms: {value}")
    return Window(window_id=str(value["window_id"]), start_ms=start_ms, end_ms=end_ms)


def _parse_roi(value: dict[str, Any]) -> Roi:
    rect_norm = {key: float(value["rect_norm"][key]) for key in ("x", "y", "w", "h")}
    out_of_frame = (
        rect_norm["x"] < 0.0
        or rect_norm["y"] < 0.0
        or rect_norm["w"] <= 0.0
        or rect_norm["h"] <= 0.0
        or rect_norm["x"] + rect_norm["w"] > 1.0
        or rect_norm["y"] + rect_norm["h"] > 1.0
    )
    return Roi(
        roi_id=str(value["roi_id"]),
        kind=str(value["kind"]),
        counts_as_avatar_motion=bool(value["counts_as_avatar_motion"]),
        expected_for_pass=bool(value["expected_for_pass"]),
        rect_norm=rect_norm,
        out_of_frame=out_of_frame,
    )


def _safe_source_ref_id(value: str) -> str:
    normalized = value.strip().lower()
    if (
        SAFE_REDACTED_SOURCE_REF_PATTERN.fullmatch(normalized)
        and "/" not in normalized
        and "\\" not in normalized
    ):
        return normalized
    digest = hashlib.sha1(value.encode("utf-8")).hexdigest()[:12]
    return f"redacted_source_{digest}"


def _safe_source_ref_kind(value: str) -> str:
    return value if value in SOURCE_REF_KINDS else "local_frame_sequence"


def _rows_from_controlled_chrome_window_metrics(
    metrics: Any,
    *,
    analysis_run_id: str,
    windows: list[Window],
    rois: list[Roi],
) -> list[dict[str, Any]]:
    if not isinstance(metrics, list):
        raise ValueError("controlled_chrome_observation.roi_window_metrics must be a list")
    window_by_id = {window.window_id: window for window in windows}
    roi_by_id = {roi.roi_id: roi for roi in rois}
    rows: list[dict[str, Any]] = []
    for metric in metrics:
        if not isinstance(metric, dict):
            raise ValueError("controlled Chrome ROI/window metric entries must be objects")
        roi_id = str(metric.get("roi_id", ""))
        window_id = str(metric.get("window_id", metric.get("time_window", "")))
        if roi_id not in roi_by_id:
            raise ValueError(f"controlled Chrome ROI/window metric references unknown ROI: {roi_id}")
        if window_id not in window_by_id:
            raise ValueError(f"controlled Chrome ROI/window metric references unknown window: {window_id}")
        roi = roi_by_id[roi_id]
        window = window_by_id[window_id]
        sample_count = max(1, int(metric.get("sample_count", 1)))
        sample_count = min(sample_count, 60)
        motion_score = _safe_metric_value(metric.get("motion_score", metric.get("movement_score", 0.0)))
        changed_ratio = _safe_metric_value(metric.get("changed_pixel_ratio", metric.get("changed_ratio", motion_score)))
        optical_flow_mean = _safe_metric_value(metric.get("optical_flow_mean", 0.0))
        optical_flow_p95 = _safe_metric_value(metric.get("optical_flow_p95", 0.0))
        bbox_delta = _safe_metric_value(metric.get("bbox_delta", 0.0))
        centroid_delta = _safe_metric_value(metric.get("centroid_delta", 0.0))
        ssim_to_baseline = _safe_metric_value(metric.get("ssim_to_baseline", 1.0 - min(motion_score, 1.0)))
        for index in range(sample_count):
            if sample_count == 1:
                time_ms = (window.start_ms + window.end_ms) // 2
            else:
                span = max(1, window.end_ms - window.start_ms - 1)
                time_ms = window.start_ms + int(round((index + 0.5) * span / sample_count))
            rows.append(
                {
                    "analysis_run_id": analysis_run_id,
                    "time_ms": time_ms,
                    "window_id": window.window_id,
                    "roi_id": roi.roi_id,
                    "roi_kind": roi.kind,
                    "counts_as_avatar_motion": roi.counts_as_avatar_motion,
                    "changed_pixel_ratio": round(changed_ratio, 6),
                    "optical_flow_mean": round(optical_flow_mean, 6),
                    "optical_flow_p95": round(optical_flow_p95, 6),
                    "bbox_delta": round(bbox_delta, 6),
                    "centroid_delta": round(centroid_delta, 6),
                    "ssim_to_baseline": round(ssim_to_baseline, 6),
                    "motion_score": round(motion_score, 6),
                    "pass_label": "",
                }
            )
    return rows


def _safe_metric_value(value: Any) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return 0.0
    return _clamp(parsed, 0.0, 1.0)


def _controlled_chrome_sample_count(rows: list[dict[str, Any]]) -> int:
    return len({int(row.get("time_ms", 0)) for row in rows})


def _reject_raw_evidence_flags(observation: dict[str, Any]) -> None:
    raw_flag_keys = {
        "raw_frame_included",
        "raw_screenshot_included",
        "raw_video_included",
        "raw_media_included",
        "raw_log_included",
        "raw_path_included",
        "local_path_included",
        "private_path_included",
        "provider_payload_included",
        "cookies_included",
        "local_storage_included",
        "session_storage_included",
        "session_store_included",
        "passwords_included",
        "unrelated_tabs_included",
    }
    for key in raw_flag_keys:
        if observation.get(key) is True:
            raise ValueError(
                "controlled Chrome Self Mirror observation must be summary-only; "
                f"raw/private flag is true: {key}"
            )


def _safe_capture_target_identity(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    allowed = {
        "schema_version",
        "capture_surface_kind",
        "chrome_tab_safe_id",
        "safe_target_id",
        "target_id",
        "visual_session_id",
        "projection_visual_instance_id",
        "surface_class",
        "surface_instance_id",
        "same_page_or_target",
        "explicitly_correlated",
        "target_identity_match",
        "surface_match",
        "browser_process_kind",
        "proof_ceiling",
        "target_identity_status",
        "surface_match_status",
        "capture_target_url_present",
        "trigger_target_url_present",
    }
    safe: dict[str, Any] = {
        "schema_version": "self_mirror_capture_target_identity.v0",
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_video_included": False,
        "local_path_included": False,
    }
    for key, item in value.items():
        if key not in allowed:
            if key in {"capture_target_url", "trigger_target_url"}:
                safe[f"{key}_present"] = True
            continue
        copied = _safe_diagnostic_value(item)
        if copied is not None:
            safe[key] = copied
    return safe


def _normalized_event_timeline(
    event_timeline: dict[str, Any] | None,
    projection_visual_diagnostics: dict[str, Any] | None,
) -> dict[str, Any]:
    safe = _safe_event_timeline(event_timeline)
    diagnostics = _safe_projection_visual_diagnostics(projection_visual_diagnostics)
    nested_timeline = diagnostics.get("event_timeline")
    if isinstance(nested_timeline, dict):
        for key, value in _safe_event_timeline(nested_timeline).items():
            safe.setdefault(key, value)
    for field_name in EVENT_ANCHORS.values():
        value = _safe_numeric_ms(diagnostics, field_name)
        if value is not None:
            safe.setdefault(field_name, value)
    return safe


def _controlled_chrome_projection_visual_diagnostics(
    configured: Any,
    *,
    observation: dict[str, Any],
    target_identity: dict[str, Any],
) -> dict[str, Any]:
    diagnostics: dict[str, Any] = {}
    if isinstance(configured, dict):
        diagnostics.update(configured)
    if isinstance(observation.get("projection_visual_diagnostics"), dict):
        diagnostics.update(observation["projection_visual_diagnostics"])
    for key in (
        "visual_session_id",
        "projection_visual_instance_id",
        "surface_class",
        "surface_instance_id",
        "same_page_or_target",
        "target_identity_match",
        "surface_match",
        "target_identity_status",
        "surface_match_status",
    ):
        if key in target_identity:
            diagnostics[key] = target_identity[key]
    if isinstance(observation.get("event_timeline"), dict):
        diagnostics["event_timeline"] = observation["event_timeline"]
    return diagnostics


def _safe_controlled_chrome_observation_summary(
    observation: dict[str, Any],
    *,
    target_identity: dict[str, Any],
) -> dict[str, Any]:
    cleanup_status = observation.get("cleanup_status", {})
    if not isinstance(cleanup_status, dict):
        cleanup_status = {}
    safe_cleanup = {
        key: value
        for key, value in cleanup_status.items()
        if key
        in {
            "browser_target_finalized",
            "runtime_stopped",
            "raw_frames_deleted",
            "temporary_config_deleted",
            "local_listener_after_cleanup",
        }
        and not _looks_like_path_or_secret(value)
    }
    return {
        "schema_version": "self_mirror_controlled_chrome_observation.v0",
        "source_kind": "controlled_chrome_metric_summary",
        "capture_target_identity": target_identity,
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_video_included": False,
        "raw_log_included": False,
        "local_path_included": False,
        "provider_payload_included": False,
        "cleanup_status": safe_cleanup,
    }


def _safe_activation_sampling(value: str) -> str:
    return value if value in ACTIVATION_SAMPLING_MODES else "event_driven"


def _safe_evidence_export(value: str) -> str:
    return value if value in EVIDENCE_EXPORT_LEVELS else "verification_capture"


def _read_frame(path: Path) -> np.ndarray:
    frame = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if frame is None:
        raise ValueError("failed to read frame")
    return frame


def _generate_synthetic_fixture_frames(
    fixture: dict[str, Any],
    *,
    windows: list[dict[str, Any]],
    rois: list[dict[str, Any]],
    sample_rate_fps: float,
) -> list[np.ndarray]:
    frame_count = int(fixture.get("frame_count", 48))
    width = int(fixture.get("width", 640))
    height = int(fixture.get("height", 360))
    if frame_count <= 0:
        raise ValueError("synthetic_fixture.frame_count must be greater than 0")
    if width <= 0 or height <= 0:
        raise ValueError("synthetic_fixture width and height must be greater than 0")

    parsed_windows = [_parse_window(window) for window in windows]
    parsed_rois = [_parse_roi(roi) for roi in rois]
    expected_avatar_roi_ids = {
        str(value)
        for value in fixture.get(
            "avatar_motion_roi_ids",
            [
                roi.roi_id
                for roi in parsed_rois
                if roi.counts_as_avatar_motion and roi.expected_for_pass
            ],
        )
    }
    guard_motion_roi_ids = {str(value) for value in fixture.get("guard_motion_roi_ids", [])}
    motion_amplitude_px = int(fixture.get("motion_amplitude_px", max(8, width // 64)))
    frames: list[np.ndarray] = []

    for frame_index in range(frame_count):
        time_ms = int(round(frame_index * 1000.0 / sample_rate_fps))
        window_id = _window_id_at(time_ms, parsed_windows)
        frame = _synthetic_base_frame(width, height, parsed_rois)
        for roi in parsed_rois:
            if roi.roi_id in expected_avatar_roi_ids:
                _draw_synthetic_motion_marker(
                    frame,
                    roi,
                    frame_index=frame_index,
                    window_id=window_id,
                    amplitude_px=motion_amplitude_px,
                    color=(238, 246, 255),
                )
            elif roi.roi_id in guard_motion_roi_ids:
                _draw_synthetic_motion_marker(
                    frame,
                    roi,
                    frame_index=frame_index,
                    window_id=window_id,
                    amplitude_px=motion_amplitude_px,
                    color=(255, 225, 82),
                )
        frames.append(frame)
    return frames


def _synthetic_base_frame(width: int, height: int, rois: list[Roi]) -> np.ndarray:
    frame = np.zeros((height, width, 3), dtype=np.uint8)
    frame[:, :] = (20, 92, 46)
    for roi in rois:
        x0, y0, x1, y1 = _roi_pixels(roi, width, height)
        if roi.kind == "avatar":
            cv2.rectangle(frame, (x0, y0), (x1, y1), (66, 82, 102), thickness=-1)
            cv2.rectangle(frame, (x0, y0), (x1, y1), (118, 141, 166), thickness=2)
        elif roi.kind == "guard_ui":
            cv2.rectangle(frame, (x0, y0), (x1, y1), (30, 34, 42), thickness=-1)
            cv2.rectangle(frame, (x0, y0), (x1, y1), (88, 104, 126), thickness=2)
        else:
            cv2.rectangle(frame, (x0, y0), (x1, y1), (18, 70, 84), thickness=-1)
    return frame


def _draw_synthetic_motion_marker(
    frame: np.ndarray,
    roi: Roi,
    *,
    frame_index: int,
    window_id: str,
    amplitude_px: int,
    color: tuple[int, int, int],
) -> None:
    height, width = frame.shape[:2]
    x0, y0, x1, y1 = _roi_pixels(roi, width, height)
    roi_width = max(1, x1 - x0)
    roi_height = max(1, y1 - y0)
    marker_width = max(4, roi_width // 3)
    marker_height = max(4, roi_height // 3)
    base_x = x0 + roi_width // 2 - marker_width // 2
    base_y = y0 + roi_height // 2 - marker_height // 2
    if window_id == "active":
        offset_x = int(round(math.sin(frame_index * 0.9) * amplitude_px))
        offset_y = int(round(math.cos(frame_index * 0.7) * max(2, amplitude_px // 2)))
    else:
        offset_x = 0
        offset_y = 0
    px0 = max(x0, min(x1 - marker_width, base_x + offset_x))
    py0 = max(y0, min(y1 - marker_height, base_y + offset_y))
    cv2.rectangle(frame, (px0, py0), (px0 + marker_width, py0 + marker_height), color, thickness=-1)


def _roi_pixels(roi: Roi, width: int, height: int) -> tuple[int, int, int, int]:
    rect = roi.rect_norm
    x0 = int(round(_clamp(rect["x"], 0.0, 1.0) * width))
    y0 = int(round(_clamp(rect["y"], 0.0, 1.0) * height))
    x1 = int(round(_clamp(rect["x"] + rect["w"], 0.0, 1.0) * width))
    y1 = int(round(_clamp(rect["y"] + rect["h"], 0.0, 1.0) * height))
    x1 = max(x0 + 1, min(width, x1))
    y1 = max(y0 + 1, min(height, y1))
    return x0, y0, x1, y1


def _window_id_at(time_ms: int, windows: Iterable[Window]) -> str:
    for window in windows:
        if window.start_ms <= time_ms < window.end_ms:
            return window.window_id
    return "outside"


def _measure_roi(
    frame: np.ndarray,
    previous: np.ndarray,
    baseline: np.ndarray,
    *,
    roi: Roi,
    analysis_run_id: str,
    time_ms: int,
    window_id: str,
) -> dict[str, Any]:
    crop = _crop(frame, roi)
    prev_crop = _crop(previous, roi)
    base_crop = _crop(baseline, roi)
    gray = _gray(crop)
    prev_gray = _gray(prev_crop)
    base_gray = _gray(base_crop)

    diff_prev = np.abs(gray - prev_gray)
    diff_base = np.abs(gray - base_gray)
    changed_pixel_ratio = _clamp(float(np.mean(diff_prev > 0.06)), 0.0, 1.0)
    flow_mean, flow_p95 = _optical_flow(prev_gray, gray)
    bbox_delta, centroid_delta = _motion_mask_stats(diff_prev > 0.06)
    ssim_to_baseline = _ssim(base_gray, gray)
    motion_score = _clamp(
        max(
            changed_pixel_ratio,
            min(flow_p95 / 12.0, 1.0),
            bbox_delta,
            centroid_delta,
            1.0 - ssim_to_baseline if np.mean(diff_base) > 0.01 else 0.0,
        ),
        0.0,
        1.0,
    )
    return {
        "analysis_run_id": analysis_run_id,
        "time_ms": time_ms,
        "window_id": window_id,
        "roi_id": roi.roi_id,
        "roi_kind": roi.kind,
        "counts_as_avatar_motion": roi.counts_as_avatar_motion,
        "changed_pixel_ratio": round(changed_pixel_ratio, 6),
        "optical_flow_mean": round(flow_mean, 6),
        "optical_flow_p95": round(flow_p95, 6),
        "bbox_delta": round(bbox_delta, 6),
        "centroid_delta": round(centroid_delta, 6),
        "ssim_to_baseline": round(ssim_to_baseline, 6),
        "motion_score": round(motion_score, 6),
        "pass_label": "",
    }


def _crop(frame: np.ndarray, roi: Roi) -> np.ndarray:
    height, width = frame.shape[:2]
    rect = roi.rect_norm
    x0 = int(round(_clamp(rect["x"], 0.0, 1.0) * width))
    y0 = int(round(_clamp(rect["y"], 0.0, 1.0) * height))
    x1 = int(round(_clamp(rect["x"] + rect["w"], 0.0, 1.0) * width))
    y1 = int(round(_clamp(rect["y"] + rect["h"], 0.0, 1.0) * height))
    x1 = max(x0 + 1, min(width, x1))
    y1 = max(y0 + 1, min(height, y1))
    return frame[y0:y1, x0:x1]


def _gray(frame: np.ndarray) -> np.ndarray:
    return cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0


def _optical_flow(previous: np.ndarray, current: np.ndarray) -> tuple[float, float]:
    if previous.shape != current.shape or previous.size == 0:
        return 0.0, 0.0
    flow = cv2.calcOpticalFlowFarneback(
        previous,
        current,
        None,
        pyr_scale=0.5,
        levels=1,
        winsize=9,
        iterations=2,
        poly_n=5,
        poly_sigma=1.1,
        flags=0,
    )
    magnitude = np.sqrt(flow[..., 0] * flow[..., 0] + flow[..., 1] * flow[..., 1])
    return _clamp(float(np.mean(magnitude)), 0.0, 1000.0), _clamp(float(np.percentile(magnitude, 95)), 0.0, 1000.0)


def _motion_mask_stats(mask: np.ndarray) -> tuple[float, float]:
    points = cv2.findNonZero(mask.astype(np.uint8))
    if points is None:
        return 0.0, 0.0
    x, y, width, height = cv2.boundingRect(points)
    bbox_delta = _clamp(float(width * height) / float(mask.shape[0] * mask.shape[1]), 0.0, 1.0)
    moments = cv2.moments(points)
    if moments["m00"] == 0:
        return bbox_delta, 0.0
    cx = float(moments["m10"] / moments["m00"])
    cy = float(moments["m01"] / moments["m00"])
    center_x = mask.shape[1] / 2.0
    center_y = mask.shape[0] / 2.0
    diagonal = math.sqrt(mask.shape[0] * mask.shape[0] + mask.shape[1] * mask.shape[1])
    centroid_delta = math.sqrt((cx - center_x) ** 2 + (cy - center_y) ** 2) / max(1.0, diagonal)
    return bbox_delta, _clamp(centroid_delta, 0.0, 1.0)


def _ssim(first: np.ndarray, second: np.ndarray) -> float:
    if first.shape != second.shape or first.size == 0:
        return 0.0
    mu_x = float(np.mean(first))
    mu_y = float(np.mean(second))
    var_x = float(np.var(first))
    var_y = float(np.var(second))
    cov_xy = float(np.mean((first - mu_x) * (second - mu_y)))
    c1 = 0.01 * 0.01
    c2 = 0.03 * 0.03
    numerator = (2 * mu_x * mu_y + c1) * (2 * cov_xy + c2)
    denominator = (mu_x * mu_x + mu_y * mu_y + c1) * (var_x + var_y + c2)
    if denominator == 0:
        return 1.0
    return _clamp(numerator / denominator, 0.0, 1.0)


def _summarize_rois(rows: list[dict[str, Any]], rois: list[Roi], thresholds: dict[str, Any]) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    active_threshold = float(thresholds["active_motion_min_score"])
    settle_threshold = float(thresholds["settle_motion_max_score"])
    min_consecutive_samples = max(1, int(thresholds["min_consecutive_samples"]))
    for roi in rois:
        roi_rows = [row for row in rows if row["roi_id"] == roi.roi_id]
        pretrigger_peak = _peak(roi_rows, "pretrigger")
        active_peak = _peak(roi_rows, "active")
        release_peak = _peak(roi_rows, "release")
        settle_peak = _peak(roi_rows, "settle")
        if roi.out_of_frame:
            label = ROI_OUT_OF_FRAME_LABEL
        elif roi.counts_as_avatar_motion and roi.expected_for_pass:
            active_run = _max_consecutive_at_or_above(roi_rows, "active", active_threshold)
            if pretrigger_peak >= active_threshold:
                label = PRETRIGGER_LABEL
            elif active_run >= min_consecutive_samples and settle_peak <= settle_threshold:
                label = AVATAR_PASS_LABEL
            elif settle_peak > settle_threshold:
                label = SETTLE_JITTER_LABEL
            else:
                label = MISSING_MOTION_LABEL
        elif roi.counts_as_avatar_motion:
            label = AVATAR_NOT_REQUIRED_LABEL
        else:
            label = GUARD_EXCLUDED_LABEL
        results.append(
            {
                "roi_id": roi.roi_id,
                "kind": roi.kind,
                "counts_as_avatar_motion": roi.counts_as_avatar_motion,
                "expected_for_pass": roi.expected_for_pass,
                "out_of_frame": roi.out_of_frame,
                "pretrigger_peak_motion_score": round(pretrigger_peak, 6),
                "active_peak_motion_score": round(active_peak, 6),
                "release_peak_motion_score": round(release_peak, 6),
                "settle_peak_motion_score": round(settle_peak, 6),
                "pass_label": label,
            }
        )
    return results


def _overall_result(
    roi_results: list[dict[str, Any]],
    thresholds: dict[str, Any],
    *,
    scenario_id: str,
    scenario_key: str,
    expected_motion: str,
    runtime_join_required: bool,
    runtime_join: dict[str, Any] | None,
    projection_visual_diagnostics: dict[str, Any] | None,
    capture_ready: dict[str, Any] | None,
    proof_layer: str,
) -> str:
    if any(row["pass_label"] == ROI_OUT_OF_FRAME_LABEL for row in roi_results):
        return ROI_OUT_OF_FRAME_LABEL
    if not _capture_is_ready(capture_ready):
        return CAPTURE_NOT_READY_LABEL
    allow_started_join = _allows_started_runtime_join(
        scenario_id=scenario_id,
        scenario_key=scenario_key,
        expected_motion=expected_motion,
    )
    allow_distinct_driver_result = _allows_distinct_runtime_driver_join(
        scenario_id=scenario_id,
        scenario_key=scenario_key,
        expected_motion=expected_motion,
    )
    if proof_layer == "visible_motion" and runtime_join_required and not _runtime_is_joined(
        runtime_join,
        allow_started=allow_started_join,
        allow_distinct_driver_result=allow_distinct_driver_result,
        started_reason_codes=_started_join_reason_codes(
            scenario_id=scenario_id,
            scenario_key=scenario_key,
            expected_motion=expected_motion,
        ),
        started_safe_visible_states=_started_join_safe_visible_states(
            scenario_id=scenario_id,
            scenario_key=scenario_key,
            expected_motion=expected_motion,
        ),
    ):
        return RUNTIME_NOT_JOINED_LABEL
    if _projection_visual_target_mismatch(projection_visual_diagnostics):
        return WRONG_TARGET_OR_SURFACE_MISMATCH_LABEL

    expected = [
        row
        for row in roi_results
        if row["counts_as_avatar_motion"] and row.get("expected_for_pass")
    ]
    guards = [
        row
        for row in roi_results
        if not row["counts_as_avatar_motion"] and not _is_diagnostic_roi(row)
    ]
    expected_pretrigger = any(row["pass_label"] == PRETRIGGER_LABEL for row in expected)
    expected_pass = bool(expected) and all(row["pass_label"] == AVATAR_PASS_LABEL for row in expected)
    expected_jitter = any(row["pass_label"] == SETTLE_JITTER_LABEL for row in expected)
    guard_motion = any(row["active_peak_motion_score"] >= float(thresholds["active_motion_min_score"]) for row in guards)
    threshold_too_strict = any(_looks_threshold_too_strict(row, thresholds) for row in expected)
    if expected_motion == "none" or not expected:
        all_motion = [
            float(row["pretrigger_peak_motion_score"])
            for row in roi_results
        ] + [
            float(row["active_peak_motion_score"])
            for row in roi_results
        ] + [
            float(row["release_peak_motion_score"])
            for row in roi_results
        ] + [
            float(row["settle_peak_motion_score"])
            for row in roi_results
        ]
        if any(float(row["pretrigger_peak_motion_score"]) >= float(thresholds["active_motion_min_score"]) for row in roi_results):
            return PRETRIGGER_LABEL
        if guard_motion:
            return GUARD_ONLY_LABEL
        if any(float(row["settle_peak_motion_score"]) > float(thresholds["settle_motion_max_score"]) for row in roi_results):
            return SETTLE_JITTER_LABEL
        if max(all_motion, default=0.0) < float(thresholds["active_motion_min_score"]):
            return VISUAL_PASS
        return MISSING_MOTION_LABEL
    if expected_pretrigger:
        return PRETRIGGER_LABEL
    if expected_jitter:
        return SETTLE_JITTER_LABEL
    if expected_pass:
        return VISUAL_PASS
    if guard_motion and expected:
        return GUARD_ONLY_LABEL
    if threshold_too_strict:
        return THRESHOLD_TOO_STRICT_LABEL
    return MISSING_MOTION_LABEL


def _motion_diagnostics(
    *,
    rows: list[dict[str, Any]],
    roi_results: list[dict[str, Any]],
    thresholds: dict[str, Any],
    runtime_join: dict[str, Any] | None,
    event_timeline: dict[str, Any] | None,
    projection_visual_diagnostics: dict[str, Any] | None,
) -> dict[str, Any]:
    active_threshold = float(thresholds["active_motion_min_score"])
    idle_delta_min_score = float(thresholds.get("idle_delta_min_score", max(0.015, active_threshold * 0.35)))
    expected_ids = [
        str(row["roi_id"])
        for row in roi_results
        if bool(row.get("counts_as_avatar_motion")) and bool(row.get("expected_for_pass"))
    ]
    guard_ids = [
        str(row["roi_id"])
        for row in roi_results
        if not bool(row.get("counts_as_avatar_motion"))
        and str(row.get("kind", "")) != "diagnostic"
    ]
    diagnostic_ids = [
        str(row["roi_id"])
        for row in roi_results
        if _is_diagnostic_roi(row)
    ]
    non_expected_avatar_ids = [
        str(row["roi_id"])
        for row in roi_results
        if bool(row.get("counts_as_avatar_motion")) and not bool(row.get("expected_for_pass"))
    ]
    idle_by_roi = {
        roi_id: _peak(rows, "pretrigger", roi_id=roi_id)
        for roi_id in {str(row.get("roi_id", "")) for row in roi_results}
    }
    expected_active_ids = _roi_ids_with_event_motion(
        rows,
        roi_ids=expected_ids,
        window_ids={"active"},
        active_threshold=active_threshold,
        idle_delta_min_score=idle_delta_min_score,
        idle_by_roi=idle_by_roi,
    )
    expected_late_ids = _roi_ids_with_event_motion(
        rows,
        roi_ids=expected_ids,
        window_ids={"late_watch"},
        active_threshold=active_threshold,
        idle_delta_min_score=idle_delta_min_score,
        idle_by_roi=idle_by_roi,
    )
    diagnostic_motion_ids = _roi_ids_with_event_motion(
        rows,
        roi_ids=[*diagnostic_ids, *non_expected_avatar_ids],
        window_ids={"active", "late_watch"},
        active_threshold=active_threshold,
        idle_delta_min_score=idle_delta_min_score,
        idle_by_roi=idle_by_roi,
    )
    guard_motion_ids = _roi_ids_with_event_motion(
        rows,
        roi_ids=guard_ids,
        window_ids={"active", "late_watch"},
        active_threshold=active_threshold,
        idle_delta_min_score=idle_delta_min_score,
        idle_by_roi=idle_by_roi,
    )
    idle_like_expected_ids = [
        roi_id
        for roi_id in expected_ids
        if _peak(rows, "active", roi_id=roi_id) >= active_threshold
        and _peak(rows, "active", roi_id=roi_id) - idle_by_roi.get(roi_id, 0.0) < idle_delta_min_score
    ]
    pretrigger_contamination_ids = [
        str(row["roi_id"])
        for row in roi_results
        if bool(row.get("counts_as_avatar_motion"))
        and bool(row.get("expected_for_pass"))
        and float(row.get("pretrigger_peak_motion_score", 0.0)) >= active_threshold
    ]
    threshold_miss_ids = [
        str(row["roi_id"])
        for row in roi_results
        if bool(row.get("counts_as_avatar_motion"))
        and bool(row.get("expected_for_pass"))
        and _looks_threshold_too_strict(row, thresholds)
    ]
    first_expected_active_at = _first_event_motion_time_ms(
        rows,
        roi_ids=expected_ids,
        window_ids={"active"},
        active_threshold=active_threshold,
        idle_delta_min_score=idle_delta_min_score,
        idle_by_roi=idle_by_roi,
    )
    first_expected_late_at = _first_event_motion_time_ms(
        rows,
        roi_ids=expected_ids,
        window_ids={"late_watch"},
        active_threshold=active_threshold,
        idle_delta_min_score=idle_delta_min_score,
        idle_by_roi=idle_by_roi,
    )
    first_diagnostic_at = _first_event_motion_time_ms(
        rows,
        roi_ids=[*diagnostic_ids, *non_expected_avatar_ids],
        window_ids={"active", "late_watch"},
        active_threshold=active_threshold,
        idle_delta_min_score=idle_delta_min_score,
        idle_by_roi=idle_by_roi,
    )
    first_guard_at = _first_event_motion_time_ms(
        rows,
        roi_ids=guard_ids,
        window_ids={"active", "late_watch"},
        active_threshold=active_threshold,
        idle_delta_min_score=idle_delta_min_score,
        idle_by_roi=idle_by_roi,
    )
    safe_projection_visual_diagnostics = _safe_projection_visual_diagnostics(projection_visual_diagnostics)
    runtime_started_at_ms = _safe_numeric_ms(event_timeline, "runtime_started_at_ms")
    runtime_started = (
        _runtime_is_joined(runtime_join, allow_started=True)
        or runtime_started_at_ms is not None
        or _projection_visual_runtime_started(safe_projection_visual_diagnostics, event_timeline)
    )
    target_mismatch = _projection_visual_target_mismatch(safe_projection_visual_diagnostics)
    frame_applied = _projection_visual_frame_applied(safe_projection_visual_diagnostics, event_timeline)
    driver_applied = _projection_visual_driver_applied(safe_projection_visual_diagnostics, event_timeline)
    anchor_status = _anchor_status(
        event_timeline,
        runtime_started=runtime_started,
        driver_applied=driver_applied,
        frame_applied=frame_applied,
    )
    diagnostic_result = _diagnostic_result(
        target_mismatch=target_mismatch,
        runtime_started=runtime_started,
        frame_applied=frame_applied,
        expected_active_ids=expected_active_ids,
        expected_late_ids=expected_late_ids,
        pretrigger_contamination_ids=pretrigger_contamination_ids,
        diagnostic_motion_ids=diagnostic_motion_ids,
        guard_motion_ids=guard_motion_ids,
        idle_like_expected_ids=idle_like_expected_ids,
        threshold_miss_ids=threshold_miss_ids,
        projection_visual_diagnostics_present=bool(safe_projection_visual_diagnostics),
    )
    first_visible_motion_at_ms = first_expected_active_at
    if first_visible_motion_at_ms is None:
        first_visible_motion_at_ms = first_expected_late_at
    latency_ms = None
    if runtime_started_at_ms is not None and first_visible_motion_at_ms is not None:
        latency_ms = max(0, first_visible_motion_at_ms - runtime_started_at_ms)
    return {
        "schema_version": "self_mirror_motion_diagnostics.v0",
        "diagnostic_result": diagnostic_result,
        "event_window_classification": diagnostic_result,
        "timeline_stage": _timeline_stage(event_timeline, runtime_started=runtime_started),
        "event_timeline": _safe_event_timeline(event_timeline),
        "anchor_status": anchor_status,
        "available_anchor_ids": anchor_status["available_anchor_ids"],
        "missing_anchor_ids": anchor_status["missing_anchor_ids"],
        "anchor": "runtime_started_when_available",
        "active_window_anchor": "runtime_started_or_configured_trigger",
        "normal_window_ids": ["active"],
        "late_window_ids": ["late_watch"],
        "active_motion_min_score": round(active_threshold, 6),
        "idle_delta_min_score": round(idle_delta_min_score, 6),
        "expected_roi_ids": expected_ids,
        "expected_roi_motion_ids": expected_active_ids,
        "late_expected_roi_motion_ids": expected_late_ids,
        "pretrigger_contamination_roi_ids": pretrigger_contamination_ids,
        "roi_threshold_miss_ids": threshold_miss_ids,
        "diagnostic_roi_ids": diagnostic_ids,
        "diagnostic_roi_motion_ids": diagnostic_motion_ids,
        "guard_roi_motion_ids": guard_motion_ids,
        "idle_like_expected_roi_ids": idle_like_expected_ids,
        "projection_visual_diagnostics_present": bool(safe_projection_visual_diagnostics),
        "projection_visual_target_mismatch": target_mismatch,
        "projection_visual_driver_applied": driver_applied,
        "projection_visual_frame_applied": frame_applied,
        "projection_visual_diagnostics": safe_projection_visual_diagnostics,
        "idle_baseline_peak_by_roi": {
            roi_id: round(value, 6)
            for roi_id, value in sorted(idle_by_roi.items())
            if roi_id
        },
        "first_expected_motion_at_ms": first_expected_active_at,
        "first_late_expected_motion_at_ms": first_expected_late_at,
        "first_diagnostic_motion_at_ms": first_diagnostic_at,
        "first_guard_motion_at_ms": first_guard_at,
        "expected_motion_latency_ms": latency_ms,
        "pass_authority_from_diagnostic_roi": False,
        "raw_frame_included": False,
        "raw_screenshot_included": False,
    }


def _diagnostic_result(
    *,
    target_mismatch: bool,
    runtime_started: bool,
    frame_applied: bool,
    expected_active_ids: list[str],
    expected_late_ids: list[str],
    pretrigger_contamination_ids: list[str],
    diagnostic_motion_ids: list[str],
    guard_motion_ids: list[str],
    idle_like_expected_ids: list[str],
    threshold_miss_ids: list[str],
    projection_visual_diagnostics_present: bool,
) -> str:
    if target_mismatch:
        return WRONG_TARGET_OR_SURFACE_MISMATCH_LABEL
    if expected_active_ids:
        return "event-correlated-motion"
    if expected_late_ids:
        return DELAYED_VISIBLE_CHANGE_LABEL
    if guard_motion_ids:
        return "guard-or-ui-only-motion"
    if diagnostic_motion_ids:
        return MOTION_OUTSIDE_EXPECTED_ROI_LABEL
    if idle_like_expected_ids:
        return IDLE_ONLY_MOTION_LABEL
    if pretrigger_contamination_ids:
        return PRETRIGGER_CONTAMINATION_LABEL
    if threshold_miss_ids:
        return ROI_THRESHOLD_MISS_LABEL
    if frame_applied:
        return FRAME_APPLIED_PIXEL_STATIC_LABEL
    if runtime_started and projection_visual_diagnostics_present:
        return RUNTIME_STARTED_NO_FRAME_APPLIED_LABEL
    if runtime_started:
        return RUNTIME_STARTED_NO_VISIBLE_MOTION_LABEL
    return NO_VISIBLE_MOTION_LABEL


def _timeline_stage(event_timeline: dict[str, Any] | None, *, runtime_started: bool) -> str:
    if not event_timeline:
        return "event-timeline-unavailable" if not runtime_started else "runtime-started"
    if _safe_numeric_ms(event_timeline, "motion_requested_at_ms") is None:
        return "request-not-emitted"
    if _safe_numeric_ms(event_timeline, "bridge_dispatched_at_ms") is None:
        return "motion-requested-but-not-dispatched"
    if not runtime_started and _safe_numeric_ms(event_timeline, "runtime_started_at_ms") is None:
        return "runtime-not-started"
    return "runtime-started"


def _safe_event_timeline(event_timeline: dict[str, Any] | None) -> dict[str, Any]:
    if not event_timeline:
        return {}
    safe: dict[str, Any] = {}
    for key in (*EVENT_ANCHORS.values(), "first_visible_motion_at_ms", "capture_ended_at_ms"):
        value = _safe_numeric_ms(event_timeline, key)
        if value is not None:
            safe[key] = value
    return safe


def _safe_projection_visual_diagnostics(value: dict[str, Any] | None) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    safe: dict[str, Any] = {
        "schema_version": "projection_visual_in_page_diagnostics.v0",
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_video_included": False,
        "local_path_included": False,
    }
    allowed = {
        "visual_session_id",
        "projection_visual_instance_id",
        "surface_class",
        "surface_instance_id",
        "target_surface_class",
        "target_surface_instance_id",
        "capture_target_id",
        "roi_registry_version",
        "motion_event_id",
        "stimulus_id",
        "stimulus_instance_id",
        "runtime_result_id",
        "driver_result_id",
        "multi_stimulus_group_id",
        "runtime_status",
        "runtime_reason_code",
        "runtime_safe_visible_state",
        "surface_match_status",
        "target_identity_status",
        "last_driver_result",
        "last_driver_reason_code",
        "last_safe_visible_state",
        "last_driver_result_id",
        "driver_observed_at",
        "expression_value_state",
        "avatar_canvas_surface_class",
        "surface_separation_status",
        "frame_seq",
        "frame_timestamp_mono_ms",
        "visual_heartbeat_ms",
        "motion_requested_at_ms",
        "runtime_accepted_at_ms",
        "runtime_started_at_ms",
        "runtime_result_at_ms",
        "driver_applied_at_ms",
        "frame_applied_at_ms",
        "visual_commit_at_ms",
        "first_changed_frame_seq",
        "frame_applied_count",
        "last_weight_count",
        "last_frame_seq",
        "driver_frame_seq",
        "driver_frame_timestamp_mono_ms",
        "accepted",
        "same_page_or_target",
        "target_identity_match",
        "surface_match",
        "expression_weight_applied",
        "mixed_surface",
        "dom_overlay_is_not_avatar_canvas_proof",
        "avatar_canvas_is_not_dom_overlay_proof",
        "expression_weight_channels",
        "surface_classes",
        "dom_overlay_surface_classes",
    }
    for key, item in value.items():
        if key == "event_timeline" and isinstance(item, dict):
            safe_timeline = _safe_event_timeline(item)
            if safe_timeline:
                safe[key] = safe_timeline
            continue
        if key not in allowed:
            continue
        copied = _safe_diagnostic_value(item)
        if copied is not None:
            safe[key] = copied
    return safe if len(safe) > 5 else {}


def _safe_diagnostic_value(value: Any) -> Any:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value if abs(value) <= 1_000_000_000 else None
    if isinstance(value, float):
        if math.isfinite(value) and abs(value) <= 1_000_000_000:
            return value
        return None
    if isinstance(value, str):
        if len(value) <= 180 and not _looks_like_path_or_secret(value):
            return value
        return None
    if isinstance(value, list):
        safe_items = [_safe_diagnostic_value(item) for item in value[:16]]
        return [item for item in safe_items if item is not None]
    return None


def _projection_visual_target_mismatch(projection_visual_diagnostics: dict[str, Any] | None) -> bool:
    diagnostics = _safe_projection_visual_diagnostics(projection_visual_diagnostics)
    if not diagnostics:
        return False
    if diagnostics.get("same_page_or_target") is False:
        return True
    if diagnostics.get("target_identity_match") is False:
        return True
    if diagnostics.get("surface_match") is False:
        return True
    if diagnostics.get("mixed_surface") is True and not _projection_visual_surfaces_explicitly_separated(diagnostics):
        return True
    status_fields = (
        "surface_match_status",
        "target_identity_status",
    )
    for field in status_fields:
        status = str(diagnostics.get(field, "")).lower()
        if any(marker in status for marker in ("mismatch", "wrong-target", "wrong_surface", "surface-mismatch")):
            return True
    return False


def _projection_visual_surfaces_explicitly_separated(diagnostics: dict[str, Any]) -> bool:
    if diagnostics.get("dom_overlay_is_not_avatar_canvas_proof") is not True:
        return False
    if diagnostics.get("avatar_canvas_is_not_dom_overlay_proof") is not True:
        return False
    avatar_surface = str(
        diagnostics.get("avatar_canvas_surface_class") or diagnostics.get("surface_class") or ""
    ).lower()
    if avatar_surface != "avatar_webgl_canvas":
        return False
    surface_classes = diagnostics.get("surface_classes")
    dom_overlay_classes = diagnostics.get("dom_overlay_surface_classes")
    class_names = set()
    class_names.add(avatar_surface)
    for value in (surface_classes, dom_overlay_classes):
        if isinstance(value, list):
            class_names.update(str(item).lower() for item in value)
    return "avatar_webgl_canvas" in class_names and any(
        item.endswith("_dom_overlay") for item in class_names
    )


def _projection_visual_frame_applied(
    projection_visual_diagnostics: dict[str, Any] | None,
    event_timeline: dict[str, Any] | None,
) -> bool:
    diagnostics = _safe_projection_visual_diagnostics(projection_visual_diagnostics)
    if not diagnostics:
        return False
    try:
        if int(diagnostics.get("frame_applied_count", 0)) > 0:
            return True
    except (TypeError, ValueError):
        pass
    if diagnostics.get("expression_weight_applied") is True:
        return True
    driver_result = str(diagnostics.get("last_driver_result", "")).lower()
    if driver_result in {"applied", "frame-applied", "frame_applied", "visual-committed", "visual_committed"}:
        return True
    if _safe_numeric_ms(diagnostics, "frame_applied_at_ms") is not None:
        return True
    if _safe_numeric_ms(diagnostics, "visual_commit_at_ms") is not None:
        return True
    if _safe_numeric_ms(event_timeline, "frame_applied_at_ms") is not None:
        return True
    if _safe_numeric_ms(event_timeline, "visual_commit_at_ms") is not None:
        return True
    return False


def _projection_visual_driver_applied(
    projection_visual_diagnostics: dict[str, Any] | None,
    event_timeline: dict[str, Any] | None,
) -> bool:
    diagnostics = _safe_projection_visual_diagnostics(projection_visual_diagnostics)
    if _safe_numeric_ms(diagnostics, "driver_applied_at_ms") is not None:
        return True
    if _safe_numeric_ms(event_timeline, "driver_applied_at_ms") is not None:
        return True
    driver_result = str(diagnostics.get("last_driver_result", "")).lower()
    return driver_result in {
        "applied",
        "frame-applied",
        "frame_applied",
        "visual-committed",
        "visual_committed",
    }


def _projection_visual_runtime_started(
    projection_visual_diagnostics: dict[str, Any] | None,
    event_timeline: dict[str, Any] | None,
) -> bool:
    diagnostics = _safe_projection_visual_diagnostics(projection_visual_diagnostics)
    if _safe_numeric_ms(event_timeline, "runtime_started_at_ms") is not None:
        return True
    if not diagnostics:
        return False
    if _safe_numeric_ms(diagnostics, "runtime_started_at_ms") is not None:
        return True
    state = str(diagnostics.get("last_safe_visible_state", "")).lower()
    if state in {"motion_started", "expression_change_requested"}:
        return True
    reason = str(diagnostics.get("last_driver_reason_code", "")).lower()
    return reason in {"motion_runtime_expression_frame_queued", "motion_runtime_vrma_started"}


def _anchor_status(
    event_timeline: dict[str, Any] | None,
    *,
    runtime_started: bool = False,
    driver_applied: bool = False,
    frame_applied: bool = False,
) -> dict[str, Any]:
    safe_timeline = _safe_event_timeline(event_timeline)
    available = {
        anchor_id
        for anchor_id, field_name in EVENT_ANCHORS.items()
        if field_name in safe_timeline
    }
    support_anchor_sources: dict[str, str] = {
        anchor_id: "event_timeline"
        for anchor_id, field_name in EVENT_ANCHORS.items()
        if field_name in safe_timeline
    }
    support_flags = {
        "runtime_started": runtime_started,
        "driver_applied": driver_applied,
        "frame_applied": frame_applied,
    }
    for anchor_id, present in support_flags.items():
        if present and anchor_id not in available:
            available.add(anchor_id)
            support_anchor_sources[anchor_id] = "projection_visual_diagnostics"
    missing = [
        anchor_id
        for anchor_id, field_name in EVENT_ANCHORS.items()
        if anchor_id not in available
    ]
    return {
        "schema_version": "self_mirror_event_anchor_status.v0",
        "available_anchor_ids": sorted(available),
        "missing_anchor_ids": missing,
        "all_required_available": len(missing) == 0,
        "support_anchor_sources": support_anchor_sources,
        "raw_log_included": False,
        "raw_provider_payload_included": False,
        "local_path_included": False,
    }


def _safe_numeric_ms(value: dict[str, Any] | None, key: str) -> int | None:
    if not value or key not in value:
        return None
    try:
        parsed = int(round(float(value[key])))
    except (TypeError, ValueError):
        return None
    return parsed if parsed >= 0 else None


def _is_diagnostic_roi(roi_result: dict[str, Any]) -> bool:
    roi_id = str(roi_result.get("roi_id", ""))
    kind = str(roi_result.get("kind", ""))
    return kind == "diagnostic" or roi_id in {
        "avatar_wide",
        "full_viewport",
        "non_guard_area",
        "scene_full",
    }


def _roi_ids_with_event_motion(
    rows: list[dict[str, Any]],
    *,
    roi_ids: list[str],
    window_ids: set[str],
    active_threshold: float,
    idle_delta_min_score: float,
    idle_by_roi: dict[str, float],
) -> list[str]:
    moved: list[str] = []
    for roi_id in roi_ids:
        peak = max(
            (
                float(row.get("motion_score", 0.0))
                for row in rows
                if str(row.get("roi_id")) == roi_id and str(row.get("window_id")) in window_ids
            ),
            default=0.0,
        )
        if peak >= active_threshold and peak - idle_by_roi.get(roi_id, 0.0) >= idle_delta_min_score:
            moved.append(roi_id)
    return moved


def _first_event_motion_time_ms(
    rows: list[dict[str, Any]],
    *,
    roi_ids: list[str],
    window_ids: set[str],
    active_threshold: float,
    idle_delta_min_score: float,
    idle_by_roi: dict[str, float],
) -> int | None:
    candidates = []
    roi_set = set(roi_ids)
    for row in rows:
        roi_id = str(row.get("roi_id", ""))
        if roi_id not in roi_set or str(row.get("window_id")) not in window_ids:
            continue
        score = float(row.get("motion_score", 0.0))
        if score >= active_threshold and score - idle_by_roi.get(roi_id, 0.0) >= idle_delta_min_score:
            candidates.append(int(row.get("time_ms", 0)))
    return min(candidates) if candidates else None


def _capture_is_ready(capture_ready: dict[str, Any] | None) -> bool:
    if not capture_ready:
        return True
    if capture_ready.get("skipped") is True:
        return True
    for key in ("hasCanvas", "visualTestModeMatches", "vrmReady", "sceneVisible"):
        if key in capture_ready and capture_ready.get(key) is False:
            return False
    return True


def _allows_started_runtime_join(*, scenario_id: str, scenario_key: str, expected_motion: str) -> bool:
    scenario_tokens = {scenario_id, scenario_key}
    if expected_motion == "broad_avatar_motion" and any(
        "dance_visible_motion" in token for token in scenario_tokens
    ):
        return True
    return expected_motion == "face_visible_change" and any(
        "expression_visible_change" in token for token in scenario_tokens
    )


def _allows_distinct_runtime_driver_join(*, scenario_id: str, scenario_key: str, expected_motion: str) -> bool:
    scenario_tokens = {scenario_id, scenario_key}
    return expected_motion == "face_visible_change" and any(
        "expression_visible_change" in token for token in scenario_tokens
    )


def _started_join_reason_codes(
    *, scenario_id: str, scenario_key: str, expected_motion: str
) -> set[str] | None:
    if _allows_distinct_runtime_driver_join(
        scenario_id=scenario_id,
        scenario_key=scenario_key,
        expected_motion=expected_motion,
    ):
        return {"motion_runtime_expression_frame_queued"}
    return None


def _started_join_safe_visible_states(
    *, scenario_id: str, scenario_key: str, expected_motion: str
) -> set[str] | None:
    if _allows_distinct_runtime_driver_join(
        scenario_id=scenario_id,
        scenario_key=scenario_key,
        expected_motion=expected_motion,
    ):
        return {"expression_change_requested"}
    return None


def _runtime_is_joined(
    runtime_join: dict[str, Any] | None,
    *,
    allow_started: bool = False,
    allow_distinct_driver_result: bool = False,
    started_reason_codes: set[str] | None = None,
    started_safe_visible_states: set[str] | None = None,
) -> bool:
    if not runtime_join:
        return False
    runtime_result_id = runtime_join.get("runtime_result_id")
    driver_result_id = runtime_join.get("driver_result_id")
    result_status = runtime_join.get("result_status")
    if not runtime_result_id:
        return False
    if driver_result_id and runtime_result_id != driver_result_id:
        if not allow_distinct_driver_result:
            return False
        if not runtime_join.get("motion_event_id") or not runtime_join.get("stimulus_instance_id"):
            return False
    allowed_statuses = {"completed"}
    if allow_started:
        allowed_statuses.add("started")
    if result_status:
        result_status_text = str(result_status)
        if result_status_text not in allowed_statuses:
            return False
        if result_status_text == "started":
            if started_reason_codes and str(runtime_join.get("result_reason_code")) not in started_reason_codes:
                return False
            if (
                started_safe_visible_states
                and str(runtime_join.get("result_safe_visible_state")) not in started_safe_visible_states
            ):
                return False
    return True


def _looks_threshold_too_strict(row: dict[str, Any], thresholds: dict[str, Any]) -> bool:
    active_threshold = float(thresholds["active_motion_min_score"])
    settle_threshold = float(thresholds["settle_motion_max_score"])
    ratio = float(thresholds.get("threshold_too_strict_ratio", 0.75))
    if row.get("pass_label") != MISSING_MOTION_LABEL:
        return False
    if float(row["pretrigger_peak_motion_score"]) >= active_threshold:
        return False
    if float(row["settle_peak_motion_score"]) > settle_threshold:
        return False
    active_peak = float(row["active_peak_motion_score"])
    return active_threshold * ratio <= active_peak < active_threshold


def _safe_summary_object(value: dict[str, Any] | None) -> dict[str, Any]:
    if not value:
        return {}
    safe: dict[str, Any] = {}
    allowed = {
        "hasCanvas",
        "visualTestMode",
        "expectedVisualTestMode",
        "visualTestModeMatches",
        "vrmReady",
        "sceneVisible",
        "frameSeq",
        "analysis_run_id",
        "motion_event_id",
        "stimulus_id",
        "stimulus_instance_id",
        "planned_driver_result_id",
        "planned_runtime_result_id",
        "driver_result_id",
        "runtime_result_id",
        "multi_stimulus_group_id",
        "result_status",
        "result_reason_code",
        "result_safe_visible_state",
    }
    for key, item in value.items():
        if key in allowed and not _looks_like_path_or_secret(item):
            safe[key] = item
    return safe


def _looks_like_path_or_secret(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    lowered = value.lower()
    if "\\" in value or "/" in value:
        return True
    return any(marker in lowered for marker in ("token", "secret", "apikey", "api_key", "bearer "))


def _next_action_for_result(result: str) -> str:
    return {
        VISUAL_PASS: "Review the expected ROI peaks and keep the claim scoped to this scenario.",
        PRETRIGGER_LABEL: "Inspect pretrigger ROI peaks; rerun with a frozen baseline or later trigger.",
        MISSING_MOTION_LABEL: "Inspect expected avatar ROIs, runtime trigger delivery, and ROI placement.",
        GUARD_ONLY_LABEL: "Inspect guard ROIs and UI/HUD animation before claiming avatar motion.",
        SETTLE_JITTER_LABEL: "Inspect settle-window peaks and extend/fix the release-to-idle behavior.",
        RUNTIME_NOT_JOINED_LABEL: "Inspect the Motion Runtime result id/status before using the ROI packet.",
        CAPTURE_NOT_READY_LABEL: "Inspect Projection Visual readiness before trusting this capture.",
        ROI_OUT_OF_FRAME_LABEL: "Fix the scenario ROI rectangle before rerunning.",
        THRESHOLD_TOO_STRICT_LABEL: "Inspect near-threshold expected ROI motion and calibrate thresholds.",
        WRONG_TARGET_OR_SURFACE_MISMATCH_LABEL: (
            "Inspect helper target identity and Projection Visual surface match before using this ROI packet."
        ),
    }.get(result, "Inspect the summary and ROI peaks before making a claim.")


def _failure_sentence(result: str) -> str:
    return {
        VISUAL_PASS: "No failure classification for the scoped ROI check.",
        PRETRIGGER_LABEL: "Motion appeared before the trigger window and is not trigger-caused proof.",
        MISSING_MOTION_LABEL: "Expected avatar ROI motion did not satisfy the active-window rule.",
        GUARD_ONLY_LABEL: "Only guard/UI/background motion crossed the active threshold.",
        SETTLE_JITTER_LABEL: "Motion did not settle below the settle threshold.",
        RUNTIME_NOT_JOINED_LABEL: "The capture was not joined to the expected runtime result.",
        CAPTURE_NOT_READY_LABEL: "Projection Visual was not ready enough for this capture.",
        ROI_OUT_OF_FRAME_LABEL: "At least one ROI rectangle is outside the viewport.",
        THRESHOLD_TOO_STRICT_LABEL: "Expected ROI motion was near threshold but did not pass the configured rule.",
        WRONG_TARGET_OR_SURFACE_MISMATCH_LABEL: "The helper target identity or Projection Visual surface did not match.",
    }.get(result, "Unknown classification.")


def _peak(rows: list[dict[str, Any]], window_id: str, *, roi_id: str | None = None) -> float:
    values = [
        float(row["motion_score"])
        for row in rows
        if row["window_id"] == window_id and (roi_id is None or str(row.get("roi_id")) == roi_id)
    ]
    return max(values) if values else 0.0


def _max_consecutive_at_or_above(rows: list[dict[str, Any]], window_id: str, threshold: float) -> int:
    longest = 0
    current = 0
    for row in sorted((row for row in rows if row["window_id"] == window_id), key=lambda item: int(item["time_ms"])):
        if float(row["motion_score"]) >= threshold:
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return longest


def _clamp(value: float, low: float, high: float) -> float:
    if not math.isfinite(value):
        return low
    return min(high, max(low, value))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run bounded RR003 visual motion analysis.")
    parser.add_argument("--config", required=True, help="Local-only visual analyzer config JSON.")
    parser.add_argument("--output-dir", required=True, help="Output directory for summary JSON and CSV.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable result summary.")
    args = parser.parse_args(argv)

    config = json.loads(Path(args.config).read_text(encoding="utf-8-sig"))
    summary, rows = analyze_config(config)
    (
        self_mirror_summary_path,
        summary_path,
        csv_path,
        chart_path,
        result_path,
        manifest_path,
    ) = write_outputs(summary, rows, Path(args.output_dir))
    result = {
        "status": "ok",
        "proof_layer": summary["proof_layer"],
        "result": summary["result"],
        "self_mirror_metric_summary_file": self_mirror_summary_path.name,
        "summary_file": summary_path.name,
        "timeseries_file": csv_path.name,
        "chart_file": chart_path.name,
        "result_file": result_path.name,
        "manifest_file": manifest_path.name,
        "raw_frames_shared": False,
        "raw_paths_shared": False,
        "raw_frames_retained": bool(summary.get("artifact_policy", {}).get("raw_frames_retained", False)),
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(f"Visual Motion Analyzer: {result['status']}")
        print(f"proof_layer={result['proof_layer']}")
        print(f"result={result['result']}")
        print("raw_frames_shared=false")
        print("raw_paths_shared=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
