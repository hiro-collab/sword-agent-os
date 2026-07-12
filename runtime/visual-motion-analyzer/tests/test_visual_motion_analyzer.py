from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

from self_mirror_visual_analyzer.visual_motion_analyzer import analyze_config, analyze_frames, main, write_outputs


WINDOWS = [
    {"window_id": "active", "start_ms": 0, "end_ms": 300},
    {"window_id": "release", "start_ms": 300, "end_ms": 500},
    {"window_id": "settle", "start_ms": 500, "end_ms": 800},
]

ROIS = [
    {
        "roi_id": "avatar_face_head",
        "kind": "avatar",
        "counts_as_avatar_motion": True,
        "expected_for_pass": True,
        "rect_norm": {"x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0},
    },
    {
        "roi_id": "speech_bubble",
        "kind": "guard_ui",
        "counts_as_avatar_motion": False,
        "expected_for_pass": False,
        "rect_norm": {"x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0},
    },
]


class VisualMotionAnalyzerTest(unittest.TestCase):
    def test_expected_avatar_roi_motion_passes_without_counting_guard_roi(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_avatar_001",
            scenario_id="rr003.visible_motion.smile.no_live.v0",
            motion_event_id="mot_evt_test_avatar_001",
            stimulus_instance_id="mot_inst_test_avatar_001",
            driver_result_id="mot_drv_test_avatar_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
        )

        self.assertEqual(summary["result"], "visual-pass")
        avatar = _roi(summary, "avatar_face_head")
        guard = _roi(summary, "speech_bubble")
        self.assertEqual(avatar["pass_label"], "visual-motion-detected")
        self.assertEqual(guard["pass_label"], "guard-ui-motion-excluded")
        self.assertTrue(all(not row["counts_as_avatar_motion"] for row in rows if row["roi_id"] == "speech_bubble"))

    def test_static_post_motion_pose_is_settled_even_when_it_differs_from_baseline(self) -> None:
        frames = [_frame() for _ in range(9)]
        frames[1][10:26, 8:20] = 255
        frames[2][10:26, 12:24] = 255
        for frame in frames[3:]:
            frame[10:26, 16:28] = 255

        summary, rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_static_post_motion_001",
            scenario_id="rr003.visible_motion.static_post_motion.no_live.v0",
            motion_event_id="mot_evt_test_static_post_motion_001",
            stimulus_instance_id="mot_inst_test_static_post_motion_001",
            driver_result_id="mot_drv_test_static_post_motion_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
        )

        avatar = _roi(summary, "avatar_face_head")
        settle_rows = [
            row
            for row in rows
            if row["roi_id"] == "avatar_face_head"
            and row["window_id"] == "settle"
        ]
        self.assertEqual(summary["result"], "visual-pass")
        self.assertEqual(avatar["settle_peak_motion_score"], 0.0)
        self.assertTrue(any(row["motion_score"] > 0.0 for row in settle_rows))
        self.assertTrue(all(row["frame_motion_score"] == 0.0 for row in settle_rows))

    def test_guard_only_motion_is_not_avatar_motion(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 44:56] = 255
        frames[2][10:26, 46:58] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_guard_001",
            scenario_id="rr003.visible_motion.smile.no_live.v0",
            motion_event_id="mot_evt_test_guard_001",
            stimulus_instance_id="mot_inst_test_guard_001",
            driver_result_id="mot_drv_test_guard_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
        )

        self.assertEqual(summary["result"], "guard-only-motion")
        avatar = _roi(summary, "avatar_face_head")
        self.assertEqual(avatar["pass_label"], "visual-missing-motion")

    def test_all_expected_avatar_rois_must_move_for_multi_roi_pass(self) -> None:
        rois = [
            {
                "roi_id": "avatar_torso",
                "kind": "avatar",
                "counts_as_avatar_motion": True,
                "expected_for_pass": True,
                "rect_norm": {"x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0},
            },
            {
                "roi_id": "avatar_right_arm",
                "kind": "avatar",
                "counts_as_avatar_motion": True,
                "expected_for_pass": True,
                "rect_norm": {"x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0},
            },
        ]
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_multi_roi_001",
            scenario_id="rr003.visible_motion.dance_visible_motion.self_mirror.v0",
            motion_event_id="mot_evt_test_multi_roi_001",
            stimulus_instance_id="mot_inst_test_multi_roi_001",
            driver_result_id="mot_drv_test_multi_roi_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=rois,
            expected_motion="broad_avatar_motion",
        )

        self.assertEqual(summary["result"], "visual-missing-motion")
        self.assertEqual(_roi(summary, "avatar_torso")["pass_label"], "visual-motion-detected")
        self.assertEqual(_roi(summary, "avatar_right_arm")["pass_label"], "visual-missing-motion")

    def test_one_active_sample_does_not_pass_min_consecutive_threshold(self) -> None:
        windows = [
            {"window_id": "active", "start_ms": 0, "end_ms": 150},
            {"window_id": "release", "start_ms": 150, "end_ms": 300},
            {"window_id": "settle", "start_ms": 300, "end_ms": 500},
        ]
        frames = [_frame() for _ in range(5)]
        frames[1][10:26, 10:22] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_single_spike_001",
            scenario_id="rr003.visible_motion.smile.no_live.v0",
            motion_event_id="mot_evt_test_single_spike_001",
            stimulus_instance_id="mot_inst_test_single_spike_001",
            driver_result_id="mot_drv_test_single_spike_001",
            sample_rate_fps=10,
            windows=windows,
            rois=ROIS,
        )

        self.assertEqual(summary["result"], "visual-missing-motion")
        avatar = _roi(summary, "avatar_face_head")
        self.assertEqual(avatar["pass_label"], "visual-missing-motion")

    def test_pretrigger_avatar_motion_is_flagged(self) -> None:
        windows = [
            {"window_id": "pretrigger", "start_ms": 0, "end_ms": 200},
            {"window_id": "active", "start_ms": 200, "end_ms": 500},
            {"window_id": "release", "start_ms": 500, "end_ms": 700},
            {"window_id": "settle", "start_ms": 700, "end_ms": 900},
        ]
        frames = [_frame() for _ in range(9)]
        frames[1][10:26, 10:22] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_pretrigger_001",
            scenario_id="rr003.visible_motion.smile.no_live.v0",
            motion_event_id="mot_evt_test_pretrigger_001",
            stimulus_instance_id="mot_inst_test_pretrigger_001",
            driver_result_id="mot_drv_test_pretrigger_001",
            sample_rate_fps=10,
            windows=windows,
            rois=ROIS,
        )

        self.assertEqual(summary["result"], "visual-pretrigger-motion")
        avatar = _roi(summary, "avatar_face_head")
        self.assertEqual(avatar["pass_label"], "visual-pretrigger-motion")
        self.assertGreater(avatar["pretrigger_peak_motion_score"], 0)

    def test_late_watch_motion_is_diagnosed_separately_from_missing_motion(self) -> None:
        windows = [
            {"window_id": "pretrigger", "start_ms": 0, "end_ms": 100},
            {"window_id": "active", "start_ms": 100, "end_ms": 300},
            {"window_id": "late_watch", "start_ms": 300, "end_ms": 700},
            {"window_id": "settle", "start_ms": 700, "end_ms": 900},
        ]
        frames = [_frame() for _ in range(9)]
        frames[4][10:26, 10:22] = 255
        frames[5][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_late_watch_001",
            scenario_id="rr003.visible_motion.dance_visible_motion.self_mirror.v0",
            motion_event_id="mot_evt_test_late_watch_001",
            stimulus_instance_id="mot_inst_test_late_watch_001",
            driver_result_id="mot_drv_test_late_watch_001",
            sample_rate_fps=10,
            windows=windows,
            rois=ROIS,
            proof_layer="visible_motion",
            expected_motion="broad_avatar_motion",
            runtime_join_required=True,
            runtime_join={
                "runtime_result_id": "mot_drv_test_late_watch_001",
                "driver_result_id": "mot_drv_test_late_watch_001",
                "result_status": "started",
            },
            event_timeline={
                "user_request_at_ms": 0,
                "motion_requested_at_ms": 900,
                "bridge_dispatched_at_ms": 950,
                "runtime_started_at_ms": 1000,
            },
        )

        self.assertEqual(summary["result"], "visual-missing-motion")
        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "delayed-visible-change")
        self.assertEqual(diagnostics["timeline_stage"], "runtime-started")
        self.assertEqual(diagnostics["late_expected_roi_motion_ids"], ["avatar_face_head"])
        self.assertEqual(diagnostics["first_late_expected_motion_at_ms"], 400)

    def test_diagnostic_wide_roi_motion_marks_expected_roi_misalignment(self) -> None:
        windows = [
            {"window_id": "pretrigger", "start_ms": 0, "end_ms": 100},
            {"window_id": "active", "start_ms": 100, "end_ms": 400},
            {"window_id": "settle", "start_ms": 400, "end_ms": 700},
        ]
        rois = [
            {
                "roi_id": "avatar_face_head",
                "kind": "avatar",
                "counts_as_avatar_motion": True,
                "expected_for_pass": True,
                "rect_norm": {"x": 0.0, "y": 0.0, "w": 0.3, "h": 1.0},
            },
            {
                "roi_id": "avatar_wide",
                "kind": "diagnostic",
                "counts_as_avatar_motion": False,
                "expected_for_pass": False,
                "rect_norm": {"x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0},
            },
        ]
        frames = [_frame() for _ in range(7)]
        frames[2][10:26, 44:56] = 255
        frames[3][10:26, 46:58] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_wide_roi_001",
            scenario_id="rr003.visible_motion.expression_visible.no_live.v0",
            motion_event_id="mot_evt_test_wide_roi_001",
            stimulus_instance_id="mot_inst_test_wide_roi_001",
            driver_result_id="mot_drv_test_wide_roi_001",
            sample_rate_fps=10,
            windows=windows,
            rois=rois,
            runtime_join={
                "runtime_result_id": "mot_drv_test_wide_roi_001",
                "driver_result_id": "mot_drv_test_wide_roi_001",
                "result_status": "started",
            },
        )

        self.assertEqual(summary["result"], "visual-missing-motion")
        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "motion-outside-expected-roi")
        self.assertEqual(diagnostics["diagnostic_roi_motion_ids"], ["avatar_wide"])
        self.assertFalse(diagnostics["pass_authority_from_diagnostic_roi"])

    def test_guard_motion_is_not_reclassified_as_diagnostic_wide_motion(self) -> None:
        windows = [
            {"window_id": "pretrigger", "start_ms": 0, "end_ms": 100},
            {"window_id": "active", "start_ms": 100, "end_ms": 400},
            {"window_id": "settle", "start_ms": 400, "end_ms": 700},
        ]
        rois = [
            {
                "roi_id": "avatar_face_head",
                "kind": "avatar",
                "counts_as_avatar_motion": True,
                "expected_for_pass": True,
                "rect_norm": {"x": 0.0, "y": 0.0, "w": 0.3, "h": 1.0},
            },
            {
                "roi_id": "speech_bubble",
                "kind": "guard_ui",
                "counts_as_avatar_motion": False,
                "expected_for_pass": False,
                "rect_norm": {"x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0},
            },
            {
                "roi_id": "full_viewport",
                "kind": "diagnostic",
                "counts_as_avatar_motion": False,
                "expected_for_pass": False,
                "rect_norm": {"x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0},
            },
        ]
        frames = [_frame() for _ in range(7)]
        frames[2][10:26, 44:56] = 255
        frames[3][10:26, 46:58] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_guard_wide_roi_001",
            scenario_id="rr003.visible_motion.expression_visible.no_live.v0",
            motion_event_id="mot_evt_test_guard_wide_roi_001",
            stimulus_instance_id="mot_inst_test_guard_wide_roi_001",
            driver_result_id="mot_drv_test_guard_wide_roi_001",
            sample_rate_fps=10,
            windows=windows,
            rois=rois,
            runtime_join={
                "runtime_result_id": "mot_drv_test_guard_wide_roi_001",
                "driver_result_id": "mot_drv_test_guard_wide_roi_001",
                "result_status": "started",
            },
        )

        self.assertEqual(summary["result"], "guard-only-motion")
        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "guard-or-ui-only-motion")
        self.assertEqual(diagnostics["guard_roi_motion_ids"], ["speech_bubble"])
        self.assertEqual(diagnostics["diagnostic_roi_motion_ids"], ["full_viewport"])
        self.assertFalse(diagnostics["pass_authority_from_diagnostic_roi"])

    def test_missing_event_anchors_are_reported_without_implying_proof(self) -> None:
        frames = [_frame() for _ in range(7)]

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_missing_anchors_001",
            scenario_id="rr003.visible_motion.context_nod.no_live.v0",
            motion_event_id="mot_evt_test_missing_anchors_001",
            stimulus_instance_id="mot_inst_test_missing_anchors_001",
            driver_result_id="mot_drv_test_missing_anchors_001",
            sample_rate_fps=10,
            windows=[
                {"window_id": "pretrigger", "start_ms": 0, "end_ms": 100},
                {"window_id": "active", "start_ms": 100, "end_ms": 400},
                {"window_id": "settle", "start_ms": 400, "end_ms": 700},
            ],
            rois=ROIS,
            runtime_join={
                "runtime_result_id": "mot_drv_test_missing_anchors_001",
                "driver_result_id": "mot_drv_test_missing_anchors_001",
                "result_status": "started",
            },
            event_timeline={"capture_started_at_ms": 0},
        )

        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "runtime-started-no-visible-motion")
        self.assertEqual(diagnostics["timeline_stage"], "request-not-emitted")
        self.assertIn("capture_started", diagnostics["available_anchor_ids"])
        self.assertIn("motion_requested", diagnostics["missing_anchor_ids"])
        self.assertIn("bridge_dispatched", diagnostics["missing_anchor_ids"])
        self.assertFalse(diagnostics["anchor_status"]["all_required_available"])
        self.assertFalse(diagnostics["anchor_status"]["raw_log_included"])

    def test_idle_like_motion_is_distinguished_from_event_correlated_motion(self) -> None:
        windows = [
            {"window_id": "pretrigger", "start_ms": 0, "end_ms": 300},
            {"window_id": "active", "start_ms": 300, "end_ms": 600},
            {"window_id": "settle", "start_ms": 600, "end_ms": 800},
        ]
        frames = [_frame() for _ in range(8)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255
        frames[4][10:26, 10:22] = 255
        frames[5][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_idle_like_001",
            scenario_id="rr003.visible_motion.expression_visible.no_live.v0",
            motion_event_id="mot_evt_test_idle_like_001",
            stimulus_instance_id="mot_inst_test_idle_like_001",
            driver_result_id="mot_drv_test_idle_like_001",
            sample_rate_fps=10,
            windows=windows,
            rois=ROIS,
            thresholds={"active_motion_min_score": 0.08, "idle_delta_min_score": 0.02},
            runtime_join={
                "runtime_result_id": "mot_drv_test_idle_like_001",
                "driver_result_id": "mot_drv_test_idle_like_001",
                "result_status": "started",
            },
        )

        self.assertEqual(summary["result"], "visual-pretrigger-motion")
        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "idle-only-motion")
        self.assertEqual(diagnostics["idle_like_expected_roi_ids"], ["avatar_face_head"])
        self.assertEqual(diagnostics["expected_roi_motion_ids"], [])

    def test_source_ref_id_is_redacted_when_path_like_value_is_supplied(self) -> None:
        frames = [_frame() for _ in range(4)]

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_redaction_001",
            scenario_id="rr003.visible_motion.smile.no_live.v0",
            motion_event_id="mot_evt_test_redaction_001",
            stimulus_instance_id="mot_inst_test_redaction_001",
            driver_result_id="mot_drv_test_redaction_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            source_ref_id="private/source/frame001.png",
        )

        source_ref = summary["source_ref"]
        self.assertTrue(source_ref["source_ref_id"].startswith("redacted_source_"))
        self.assertNotIn("/", source_ref["source_ref_id"])

    def test_browser_frame_provider_source_kind_is_preserved(self) -> None:
        frames = [_frame() for _ in range(4)]

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_browser_kind_001",
            scenario_id="rr003.visible_motion.browser.self_mirror.v0",
            motion_event_id="mot_evt_test_browser_kind_001",
            stimulus_instance_id="mot_inst_test_browser_kind_001",
            driver_result_id="mot_drv_test_browser_kind_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            source_ref_id="redacted_browser_projection_visual_001",
            source_ref_kind="browser_frame_provider",
            proof_layer="visible_motion",
        )

        self.assertEqual(summary["source_ref"]["kind"], "browser_frame_provider")
        self.assertEqual(summary["proof_layer"], "visible_motion")

    def test_synthetic_self_mirror_fixture_does_not_need_frame_paths(self) -> None:
        synthetic_rois = [
            *ROIS,
            {
                "roi_id": "avatar_torso",
                "kind": "avatar",
                "counts_as_avatar_motion": True,
                "expected_for_pass": False,
                "rect_norm": {"x": 0.20, "y": 0.0, "w": 0.30, "h": 1.0},
            },
        ]
        config = {
            "analysis_run_id": "vismot_run_test_synthetic_self_mirror_001",
            "scenario_id": "rr003.visible_motion.self_mirror.synthetic.v0",
            "motion_event_id": "mot_evt_test_synthetic_self_mirror_001",
            "stimulus_instance_id": "mot_inst_test_synthetic_self_mirror_001",
            "driver_result_id": "mot_drv_test_synthetic_self_mirror_001",
            "proof_layer": "no_live_runtime",
            "source_ref": {
                "kind": "synthetic_test_frames",
                "source_ref_id": "redacted_synthetic_self_mirror_001",
            },
            "sampling": {"sample_rate_fps": 8},
            "synthetic_fixture": {
                "width": 320,
                "height": 180,
                "frame_count": 24,
                "avatar_motion_roi_ids": ["avatar_face_head"],
                "guard_motion_roi_ids": ["speech_bubble"],
            },
            "windows": [
                {"window_id": "pretrigger", "start_ms": 0, "end_ms": 500},
                {"window_id": "active", "start_ms": 500, "end_ms": 1800},
                {"window_id": "release", "start_ms": 1800, "end_ms": 2400},
                {"window_id": "settle", "start_ms": 2400, "end_ms": 3000},
            ],
            "rois": synthetic_rois,
            "thresholds": {
                "active_motion_min_score": 0.08,
                "settle_motion_max_score": 0.05,
                "min_consecutive_samples": 2,
            },
        }

        from self_mirror_visual_analyzer.visual_motion_analyzer import analyze_config

        summary, rows = analyze_config(config)

        self.assertEqual(summary["source_ref"]["kind"], "synthetic_test_frames")
        self.assertEqual(summary["source_ref"]["source_ref_id"], "redacted_synthetic_self_mirror_001")
        self.assertEqual(summary["result"], "visual-pass")
        self.assertEqual(_roi(summary, "avatar_face_head")["pass_label"], "visual-motion-detected")
        self.assertEqual(_roi(summary, "avatar_torso")["pass_label"], "avatar-motion-not-required")
        self.assertEqual(_roi(summary, "speech_bubble")["pass_label"], "guard-ui-motion-excluded")
        self.assertEqual(len(rows), (24 - 1) * len(synthetic_rois))

    def test_idle_baseline_without_expected_motion_can_pass(self) -> None:
        rois = [
            {
                "roi_id": "avatar_full",
                "kind": "avatar",
                "counts_as_avatar_motion": True,
                "expected_for_pass": False,
                "rect_norm": {"x": 0.2, "y": 0.0, "w": 0.6, "h": 1.0},
            },
            {
                "roi_id": "speech_bubble",
                "kind": "guard_ui",
                "counts_as_avatar_motion": False,
                "expected_for_pass": False,
                "rect_norm": {"x": 0.0, "y": 0.2, "w": 0.2, "h": 0.4},
            },
        ]

        summary, _rows = analyze_frames(
            [_frame() for _ in range(6)],
            analysis_run_id="vismot_run_test_idle_001",
            scenario_id="rr003.visible_motion.idle_baseline.no_live.v0",
            motion_event_id="mot_evt_test_idle_001",
            stimulus_instance_id="mot_inst_test_idle_001",
            driver_result_id="mot_drv_test_idle_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=rois,
            expected_motion="none",
            scenario_key="idle_baseline",
        )

        self.assertEqual(summary["result"], "visual-pass")
        self.assertEqual(summary["scenario"]["expected_motion"], "none")

    def test_idle_baseline_settle_only_motion_does_not_pass(self) -> None:
        rois = [
            {
                "roi_id": "avatar_full",
                "kind": "avatar",
                "counts_as_avatar_motion": True,
                "expected_for_pass": False,
                "rect_norm": {"x": 0.2, "y": 0.0, "w": 0.6, "h": 1.0},
            }
        ]
        frames = [_frame() for _ in range(6)]
        frames[5][25:35, 26:40] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_idle_settle_001",
            scenario_id="rr003.visible_motion.idle_baseline.no_live.v0",
            motion_event_id="mot_evt_test_idle_settle_001",
            stimulus_instance_id="mot_inst_test_idle_settle_001",
            driver_result_id="mot_drv_test_idle_settle_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=rois,
            thresholds={"active_motion_min_score": 1.0, "settle_motion_max_score": 0.05},
            expected_motion="none",
            scenario_key="idle_baseline",
        )

        self.assertEqual(summary["result"], "did-not-settle")
        avatar = _roi(summary, "avatar_full")
        self.assertGreater(avatar["settle_peak_motion_score"], 0.05)
        self.assertLess(avatar["settle_peak_motion_score"], 1.0)

    def test_visible_motion_runtime_join_required_is_classified(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_runtime_join_001",
            scenario_id="rr003.visible_motion.context_nod.browser.v0",
            motion_event_id="mot_evt_test_runtime_join_001",
            stimulus_instance_id="mot_inst_test_runtime_join_001",
            driver_result_id="mot_drv_test_runtime_join_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            runtime_join_required=True,
        )

        self.assertEqual(summary["result"], "runtime-not-joined")

    def test_dance_visible_motion_runtime_join_started_is_accepted_for_ongoing_motion(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_dance_started_join_001",
            scenario_id="rr003.visible_motion.dance_visible_motion.self_mirror.v0",
            motion_event_id="motion-event-browser-dance-sequence-1",
            stimulus_instance_id="mot_inst_browser_dance_sequence_1",
            driver_result_id="runtime-result-browser-dance-sequence-actual-1",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            expected_motion="broad_avatar_motion",
            runtime_join_required=True,
            runtime_join={
                "planned_driver_result_id": "runtime-result-planned-browser-dance-sequence-1",
                "runtime_result_id": "runtime-result-browser-dance-sequence-actual-1",
                "driver_result_id": "runtime-result-browser-dance-sequence-actual-1",
                "result_status": "started",
            },
        )

        self.assertEqual(summary["result"], "visual-pass")
        self.assertEqual(
            summary["runtime_join"]["planned_driver_result_id"],
            "runtime-result-planned-browser-dance-sequence-1",
        )

    def test_dance_visible_motion_runtime_join_missing_is_rejected(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_dance_missing_join_001",
            scenario_id="rr003.visible_motion.dance_visible_motion.self_mirror.v0",
            motion_event_id="motion-event-browser-dance-sequence-1",
            stimulus_instance_id="mot_inst_browser_dance_sequence_1",
            driver_result_id="runtime-result-browser-dance-sequence-actual-1",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            expected_motion="broad_avatar_motion",
            runtime_join_required=True,
        )

        self.assertEqual(summary["result"], "runtime-not-joined")

    def test_dance_visible_motion_runtime_join_mismatch_is_rejected(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_dance_mismatch_join_001",
            scenario_id="rr003.visible_motion.dance_visible_motion.self_mirror.v0",
            motion_event_id="motion-event-browser-dance-sequence-1",
            stimulus_instance_id="mot_inst_browser_dance_sequence_1",
            driver_result_id="runtime-result-browser-dance-sequence-actual-1",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            expected_motion="broad_avatar_motion",
            runtime_join_required=True,
            runtime_join={
                "runtime_result_id": "runtime-result-browser-dance-sequence-actual-1",
                "driver_result_id": "runtime-result-browser-dance-sequence-other-1",
                "result_status": "started",
            },
        )

        self.assertEqual(summary["result"], "runtime-not-joined")

    def test_dance_visible_motion_runtime_join_failed_or_rejected_is_rejected(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        for result_status in ("failed", "rejected"):
            with self.subTest(result_status=result_status):
                summary, _rows = analyze_frames(
                    frames,
                    analysis_run_id=f"vismot_run_test_dance_{result_status}_join_001",
                    scenario_id="rr003.visible_motion.dance_visible_motion.self_mirror.v0",
                    motion_event_id="motion-event-browser-dance-sequence-1",
                    stimulus_instance_id="mot_inst_browser_dance_sequence_1",
                    driver_result_id="runtime-result-browser-dance-sequence-actual-1",
                    sample_rate_fps=10,
                    windows=WINDOWS,
                    rois=ROIS,
                    proof_layer="visible_motion",
                    expected_motion="broad_avatar_motion",
                    runtime_join_required=True,
                    runtime_join={
                        "runtime_result_id": "runtime-result-browser-dance-sequence-actual-1",
                        "driver_result_id": "runtime-result-browser-dance-sequence-actual-1",
                        "result_status": result_status,
                    },
                )

                self.assertEqual(summary["result"], "runtime-not-joined")

    def test_expression_visible_change_runtime_join_started_is_accepted_for_queued_expression(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_expression_started_join_001",
            scenario_id="rr003.visible_motion.expression_visible_change.self_mirror.v0",
            motion_event_id="motion-event-expression-visible-browser-1",
            stimulus_instance_id="stimulus-instance-expression-visible-browser-1",
            driver_result_id="driver-result-expression-visible-browser-planned-1",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            scenario_key="expression_visible_change",
            expected_motion="face_visible_change",
            runtime_join_required=True,
            runtime_join={
                "runtime_result_id": "expression-runtime-result-browser-planned-1",
                "driver_result_id": "driver-result-expression-visible-browser-planned-1",
                "motion_event_id": "motion-event-expression-visible-browser-1",
                "stimulus_instance_id": "stimulus-instance-expression-visible-browser-1",
                "result_status": "started",
                "result_reason_code": "motion_runtime_expression_frame_queued",
                "result_safe_visible_state": "expression_change_requested",
            },
        )

        self.assertEqual(summary["result"], "visual-pass")
        self.assertEqual(summary["runtime_join"]["runtime_result_id"], "expression-runtime-result-browser-planned-1")
        self.assertEqual(summary["runtime_join"]["driver_result_id"], "driver-result-expression-visible-browser-planned-1")

    def test_expression_visible_change_started_join_requires_expression_reason_and_state(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        bad_join_overrides = [
            {"result_reason_code": "motion_runtime_context_nod_started"},
            {"result_safe_visible_state": "motion_started"},
            {"stimulus_instance_id": ""},
            {"result_status": "failed"},
            {"result_status": "rejected"},
        ]
        for overrides in bad_join_overrides:
            with self.subTest(overrides=overrides):
                runtime_join = {
                    "runtime_result_id": "expression-runtime-result-browser-planned-1",
                    "driver_result_id": "driver-result-expression-visible-browser-planned-1",
                    "motion_event_id": "motion-event-expression-visible-browser-1",
                    "stimulus_instance_id": "stimulus-instance-expression-visible-browser-1",
                    "result_status": "started",
                    "result_reason_code": "motion_runtime_expression_frame_queued",
                    "result_safe_visible_state": "expression_change_requested",
                }
                runtime_join.update(overrides)

                summary, _rows = analyze_frames(
                    frames,
                    analysis_run_id="vismot_run_test_expression_bad_started_join_001",
                    scenario_id="rr003.visible_motion.expression_visible_change.self_mirror.v0",
                    motion_event_id="motion-event-expression-visible-browser-1",
                    stimulus_instance_id="stimulus-instance-expression-visible-browser-1",
                    driver_result_id="driver-result-expression-visible-browser-planned-1",
                    sample_rate_fps=10,
                    windows=WINDOWS,
                    rois=ROIS,
                    proof_layer="visible_motion",
                    scenario_key="expression_visible_change",
                    expected_motion="face_visible_change",
                    runtime_join_required=True,
                    runtime_join=runtime_join,
                )

                self.assertEqual(summary["result"], "runtime-not-joined")

    def test_projection_visual_target_mismatch_blocks_otherwise_visible_expression_pass(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_projection_visual_wrong_target_001",
            scenario_id="rr003.visible_motion.expression_visible_change.self_mirror.v0",
            motion_event_id="motion-event-expression-visible-browser-1",
            stimulus_instance_id="stimulus-instance-expression-visible-browser-1",
            driver_result_id="driver-result-expression-visible-browser-planned-1",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            scenario_key="expression_visible_change",
            expected_motion="face_visible_change",
            runtime_join_required=True,
            runtime_join={
                "runtime_result_id": "expression-runtime-result-browser-planned-1",
                "driver_result_id": "driver-result-expression-visible-browser-planned-1",
                "motion_event_id": "motion-event-expression-visible-browser-1",
                "stimulus_instance_id": "stimulus-instance-expression-visible-browser-1",
                "result_status": "started",
                "result_reason_code": "motion_runtime_expression_frame_queued",
                "result_safe_visible_state": "expression_change_requested",
            },
            projection_visual_diagnostics={
                "same_page_or_target": False,
                "target_identity_match": False,
                "surface_match_status": "wrong-target",
                "raw_frame_included": True,
                "local_path_included": True,
            },
        )

        self.assertEqual(summary["result"], "wrong-target-or-surface-mismatch")
        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "wrong-target-or-surface-mismatch")
        self.assertTrue(diagnostics["projection_visual_target_mismatch"])
        self.assertFalse(summary["projection_visual_diagnostics"]["raw_frame_included"])
        self.assertFalse(summary["projection_visual_diagnostics"]["local_path_included"])

    def test_projection_visual_frame_applied_but_pixels_static_is_diagnosed(self) -> None:
        frames = [_frame() for _ in range(6)]

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_projection_visual_frame_static_001",
            scenario_id="rr003.visible_motion.expression_visible_change.self_mirror.v0",
            motion_event_id="motion-event-expression-visible-browser-1",
            stimulus_instance_id="stimulus-instance-expression-visible-browser-1",
            driver_result_id="driver-result-expression-visible-browser-planned-1",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            scenario_key="expression_visible_change",
            expected_motion="face_visible_change",
            runtime_join_required=True,
            runtime_join={
                "runtime_result_id": "expression-runtime-result-browser-planned-1",
                "driver_result_id": "driver-result-expression-visible-browser-planned-1",
                "motion_event_id": "motion-event-expression-visible-browser-1",
                "stimulus_instance_id": "stimulus-instance-expression-visible-browser-1",
                "result_status": "started",
                "result_reason_code": "motion_runtime_expression_frame_queued",
                "result_safe_visible_state": "expression_change_requested",
            },
            event_timeline={
                "runtime_started_at_ms": 100,
                "driver_applied_at_ms": 125,
                "frame_applied_at_ms": 150,
            },
            projection_visual_diagnostics={
                "same_page_or_target": True,
                "target_identity_match": True,
                "surface_match": True,
                "frame_applied_count": 1,
                "expression_weight_applied": True,
                "last_driver_result": "applied",
            },
        )

        self.assertEqual(summary["result"], "visual-missing-motion")
        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "frame-applied-but-pixel-static")
        self.assertTrue(diagnostics["projection_visual_frame_applied"])
        self.assertIn("frame_applied", diagnostics["available_anchor_ids"])

    def test_v0_surface_separation_metadata_is_not_target_mismatch(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_projection_visual_v0_surface_separation_001",
            scenario_id="rr003.visible_motion.expression_visible_change.self_mirror.v0",
            motion_event_id="motion-event-expression-visible-browser-1",
            stimulus_instance_id="stimulus-instance-expression-visible-browser-1",
            driver_result_id="driver-result-expression-visible-browser-planned-1",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            scenario_key="expression_visible_change",
            expected_motion="face_visible_change",
            runtime_join_required=True,
            runtime_join={
                "runtime_result_id": "expression-runtime-result-browser-planned-1",
                "driver_result_id": "driver-result-expression-visible-browser-planned-1",
                "motion_event_id": "motion-event-expression-visible-browser-1",
                "stimulus_instance_id": "stimulus-instance-expression-visible-browser-1",
                "result_status": "started",
                "result_reason_code": "motion_runtime_expression_frame_queued",
                "result_safe_visible_state": "expression_change_requested",
            },
            event_timeline={"bridge_dispatched_at_ms": 10, "capture_started_at_ms": 0},
            projection_visual_diagnostics={
                "surface_class": "avatar_webgl_canvas",
                "avatar_canvas_surface_class": "avatar_webgl_canvas",
                "surface_classes": [
                    "avatar_webgl_canvas",
                    "hud_dom_overlay",
                    "speech_bubble_dom_overlay",
                ],
                "dom_overlay_surface_classes": [
                    "hud_dom_overlay",
                    "speech_bubble_dom_overlay",
                ],
                "dom_overlay_is_not_avatar_canvas_proof": True,
                "avatar_canvas_is_not_dom_overlay_proof": True,
                "surface_separation_status": "separated",
                "mixed_surface": True,
                "frame_applied_count": 1,
                "expression_weight_applied": True,
                "last_driver_result": "applied",
            },
        )

        self.assertEqual(summary["result"], "visual-pass")
        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "event-correlated-motion")
        self.assertFalse(diagnostics["projection_visual_target_mismatch"])
        self.assertTrue(diagnostics["projection_visual_frame_applied"])
        safe_diagnostics = diagnostics["projection_visual_diagnostics"]
        self.assertEqual(safe_diagnostics["surface_separation_status"], "separated")
        self.assertTrue(safe_diagnostics["dom_overlay_is_not_avatar_canvas_proof"])
        self.assertTrue(safe_diagnostics["avatar_canvas_is_not_dom_overlay_proof"])
        self.assertIn("speech_bubble_dom_overlay", safe_diagnostics["dom_overlay_surface_classes"])

    def test_projection_visual_runtime_started_without_frame_applied_is_diagnosed(self) -> None:
        frames = [_frame() for _ in range(6)]

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_projection_visual_no_frame_applied_001",
            scenario_id="rr003.visible_motion.expression_visible_change.self_mirror.v0",
            motion_event_id="motion-event-expression-visible-browser-1",
            stimulus_instance_id="stimulus-instance-expression-visible-browser-1",
            driver_result_id="driver-result-expression-visible-browser-planned-1",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            scenario_key="expression_visible_change",
            expected_motion="face_visible_change",
            runtime_join_required=True,
            runtime_join={
                "runtime_result_id": "expression-runtime-result-browser-planned-1",
                "driver_result_id": "driver-result-expression-visible-browser-planned-1",
                "motion_event_id": "motion-event-expression-visible-browser-1",
                "stimulus_instance_id": "stimulus-instance-expression-visible-browser-1",
                "result_status": "started",
                "result_reason_code": "motion_runtime_expression_frame_queued",
                "result_safe_visible_state": "expression_change_requested",
            },
            event_timeline={"runtime_started_at_ms": 100},
            projection_visual_diagnostics={
                "same_page_or_target": True,
                "target_identity_match": True,
                "surface_match": True,
                "frame_applied_count": 0,
                "last_safe_visible_state": "expression_change_requested",
            },
        )

        self.assertEqual(summary["result"], "visual-missing-motion")
        diagnostics = summary["motion_diagnostics"]
        self.assertEqual(diagnostics["diagnostic_result"], "runtime-started-but-no-frame-applied")
        self.assertFalse(diagnostics["projection_visual_frame_applied"])

    def test_capture_not_ready_is_classified_before_motion_pass(self) -> None:
        frames = [_frame() for _ in range(6)]
        frames[1][10:26, 10:22] = 255
        frames[2][10:26, 12:24] = 255

        summary, _rows = analyze_frames(
            frames,
            analysis_run_id="vismot_run_test_capture_ready_001",
            scenario_id="rr003.visible_motion.context_nod.browser.v0",
            motion_event_id="mot_evt_test_capture_ready_001",
            stimulus_instance_id="mot_inst_test_capture_ready_001",
            driver_result_id="mot_drv_test_capture_ready_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=ROIS,
            proof_layer="visible_motion",
            capture_ready={"hasCanvas": True, "vrmReady": False, "sceneVisible": True},
        )

        self.assertEqual(summary["result"], "capture-not-ready")

    def test_roi_out_of_frame_is_classified(self) -> None:
        rois = [
            {
                "roi_id": "avatar_full",
                "kind": "avatar",
                "counts_as_avatar_motion": True,
                "expected_for_pass": True,
                "rect_norm": {"x": 0.8, "y": 0.0, "w": 0.4, "h": 1.0},
            }
        ]

        summary, _rows = analyze_frames(
            [_frame() for _ in range(6)],
            analysis_run_id="vismot_run_test_roi_frame_001",
            scenario_id="rr003.visible_motion.context_nod.no_live.v0",
            motion_event_id="mot_evt_test_roi_frame_001",
            stimulus_instance_id="mot_inst_test_roi_frame_001",
            driver_result_id="mot_drv_test_roi_frame_001",
            sample_rate_fps=10,
            windows=WINDOWS,
            rois=rois,
        )

        self.assertEqual(summary["result"], "roi-out-of-frame")
        self.assertEqual(_roi(summary, "avatar_full")["pass_label"], "roi-out-of-frame")

    def test_standard_package_writes_chart_result_and_manifest_without_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frames = [_frame() for _ in range(6)]
            frames[1][10:26, 10:22] = 255
            frames[2][10:26, 12:24] = 255
            summary, rows = analyze_frames(
                frames,
                analysis_run_id="vismot_run_test_package_001",
                scenario_id="rr003.visible_motion.context_nod.no_live.v0",
                motion_event_id="mot_evt_test_package_001",
                stimulus_instance_id="mot_inst_test_package_001",
                driver_result_id="mot_drv_test_package_001",
                sample_rate_fps=10,
                windows=[
                    {"window_id": "pretrigger", "start_ms": 0, "end_ms": 50},
                    {"window_id": "active", "start_ms": 50, "end_ms": 300},
                    {"window_id": "release", "start_ms": 300, "end_ms": 500},
                    {"window_id": "settle", "start_ms": 500, "end_ms": 800},
                ],
                rois=ROIS,
                source_ref_id=str(root / "private_source"),
            )

            (
                self_mirror_summary_path,
                summary_path,
                csv_path,
                chart_path,
                result_path,
                manifest_path,
            ) = write_outputs(summary, rows, root)

            for path in (self_mirror_summary_path, summary_path, csv_path, chart_path, result_path, manifest_path):
                self.assertTrue(path.exists(), path)
            self_mirror_summary = json.loads(self_mirror_summary_path.read_text(encoding="utf-8"))
            chart = chart_path.read_text(encoding="utf-8")
            result_text = result_path.read_text(encoding="utf-8")
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(self_mirror_summary["schema_version"], "self_mirror_metric_summary.v0")
            self.assertFalse(self_mirror_summary["raw_frame_included"])
            self.assertFalse(self_mirror_summary["raw_screenshot_included"])
            self.assertEqual(self_mirror_summary["activation_sampling"], "event_driven")
            self.assertEqual(self_mirror_summary["evidence_export"], "verification_capture")
            self.assertTrue(self_mirror_summary["observation_policy"]["timeline_export_expected"])
            self.assertFalse(self_mirror_summary["observation_policy"]["verification_capture_is_completion_proof"])
            self.assertFalse(self_mirror_summary["needs_attention"])
            self.assertEqual(self_mirror_summary["observed_issue"], "")
            self.assertEqual(self_mirror_summary["recommended_correction"], "")
            self.assertTrue(self_mirror_summary["classification"]["recommendation_is_observation_only"])
            self.assertTrue(self_mirror_summary["boundary"]["decision_boundary"]["does_not_execute_correction"])
            self.assertEqual(self_mirror_summary["latest_state"]["schema_version"], "self_mirror_observation.v0")
            self.assertFalse(self_mirror_summary["latest_state"]["direct_correction_dispatch"])
            self.assertFalse(self_mirror_summary["latest_state"]["retry_authority"])
            self.assertEqual(
                self_mirror_summary["latest_observation_ref"],
                self_mirror_summary["latest_state"]["observation_id"],
            )
            self.assertFalse(self_mirror_summary["consumer_retry_policy"]["self_mirror_is_command_channel"])
            self.assertFalse(self_mirror_summary["consumer_retry_policy"]["self_mirror_retry_authority"])
            self.assertEqual(
                self_mirror_summary["consumer_retry_policy"]["retry_limit_default"],
                2,
            )
            self.assertTrue(self_mirror_summary["consumer_retry_policy"]["retry_limit_configurable"])
            self.assertIn(
                "thought_core.self_mirror_retry.limit",
                self_mirror_summary["consumer_retry_policy"]["retry_policy_source"],
            )
            self.assertEqual(
                self_mirror_summary["consumer_retry_policy"]["retry_execution_owner"],
                "thought_core_or_output_owner",
            )
            self.assertIn(
                "retry_policy_source",
                self_mirror_summary["consumer_retry_policy"]["required_trace_fields"],
            )
            self.assertFalse(
                self_mirror_summary["consumer_retry_policy"]["failure_escalation_policy"][
                    "self_mirror_escalation_authority"
                ]
            )
            self.assertFalse(
                self_mirror_summary["consumer_retry_policy"]["external_side_effect_auto_retry_allowed"]
            )
            self.assertFalse(self_mirror_summary["latest_state"]["durable_memory_by_default"])
            self.assertEqual(
                self_mirror_summary["observation_queue"]["schema_version"],
                "self_mirror_observation_queue.v0",
            )
            self.assertEqual(self_mirror_summary["observation_queue"]["retention"], "bounded_ring_buffer")
            self.assertLessEqual(
                len(self_mirror_summary["observation_queue"]["entries"]),
                self_mirror_summary["observation_queue"]["max_entries"],
            )
            self.assertFalse(self_mirror_summary["observation_queue"]["raw_frame_included"])
            self.assertFalse(self_mirror_summary["observation_queue"]["direct_correction_dispatch"])
            self.assertEqual(
                self_mirror_summary["observation_queue"]["consumer_retry_policy"]["self_mirror_observation_ref"],
                self_mirror_summary["latest_observation_ref"],
            )
            self.assertIn("roi_window_metrics", self_mirror_summary)
            self.assertEqual(manifest["artifacts"]["self_mirror_metric_summary"], "self_mirror_metric_summary.json")
            self.assertIn("pretrigger", chart)
            self.assertIn("active threshold", chart)
            self.assertIn("Raw frames retained: no", result_text)
            self.assertEqual(manifest["artifacts"]["chart"], "visual_motion_chart.html")
            self.assertNotIn(str(root), chart)
            self.assertNotIn(str(root), result_text)

    def test_cli_json_uses_artifact_basenames_not_local_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frame_paths = []
            for index in range(4):
                frame = _frame()
                if index in (1, 2):
                    frame[10:26, 10:22] = 255
                path = root / f"frame_{index}.png"
                self.assertTrue(cv2.imwrite(str(path), frame))
                frame_paths.append(str(path))

            config_path = root / "config.json"
            output_dir = root / "out"
            config = {
                "analysis_run_id": "vismot_run_test_cli_001",
                "scenario_id": "rr003.visible_motion.smile.no_live.v0",
                "motion_event_id": "mot_evt_test_cli_001",
                "stimulus_instance_id": "mot_inst_test_cli_001",
                "driver_result_id": "mot_drv_test_cli_001",
                "proof_layer": "no_live_runtime",
                "frame_paths": frame_paths,
                "source_ref": {"source_ref_id": str(root / "private_source")},
                "sampling": {"sample_rate_fps": 10},
                "windows": WINDOWS,
                "rois": ROIS,
            }
            config_path.write_text(json.dumps(config), encoding="utf-8")

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(
                    main(["--config", str(config_path), "--output-dir", str(output_dir), "--json"]),
                    0,
                )

            output = stdout.getvalue()
            payload = json.loads(output)
            self.assertNotIn(str(root), output)
            self.assertEqual(payload["self_mirror_metric_summary_file"], "self_mirror_metric_summary.json")
            self.assertEqual(payload["summary_file"], "visual_motion_summary.json")
            self.assertEqual(payload["timeseries_file"], "visual_motion_roi_timeseries.csv")
            self.assertNotIn("summary", payload)
            self.assertNotIn("timeseries", payload)

            summary_path = output_dir / "visual_motion_summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["source_ref"]["source_ref_id"].startswith("redacted_source_"))

    def test_dance_visible_motion_scenario_is_executable_not_future_only(self) -> None:
        catalog_path = Path(__file__).resolve().parents[1] / "self-mirror-scenarios.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        scenario = catalog["scenarios"]["dance_visible_motion"]
        expected_roi_ids = {"avatar_full", "avatar_torso", "avatar_left_arm", "avatar_right_arm"}
        expected_rois = {
            str(roi["roi_id"])
            for roi in scenario["rois"]
            if bool(roi["counts_as_avatar_motion"]) and bool(roi["expected_for_pass"])
        }

        self.assertEqual(scenario["trigger"], "dance")
        self.assertEqual(scenario["expected_motion"], "broad_avatar_motion")
        self.assertTrue(scenario["runtime_join_required"])
        self.assertEqual(set(scenario["expected_avatar_roi_ids"]), expected_roi_ids)
        self.assertEqual(expected_rois, expected_roi_ids)
        self.assertEqual(set(scenario["synthetic_fixture"]["avatar_motion_roi_ids"]), expected_roi_ids)

    def test_expression_visible_change_scenario_is_executable_not_semantic_expression_proof(self) -> None:
        catalog_path = Path(__file__).resolve().parents[1] / "self-mirror-scenarios.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        scenario = catalog["scenarios"]["expression_visible_change"]
        rois = {str(roi["roi_id"]): roi for roi in scenario["rois"]}
        expected_rois = {
            str(roi["roi_id"])
            for roi in scenario["rois"]
            if bool(roi["counts_as_avatar_motion"]) and bool(roi["expected_for_pass"])
        }

        self.assertEqual(scenario["trigger"], "expression-visible")
        self.assertEqual(scenario["expected_motion"], "face_visible_change")
        self.assertTrue(scenario["runtime_join_required"])
        self.assertEqual(set(scenario["expected_avatar_roi_ids"]), {"avatar_face_head"})
        self.assertEqual(expected_rois, {"avatar_face_head"})
        self.assertEqual(set(scenario["synthetic_fixture"]["avatar_motion_roi_ids"]), {"avatar_face_head"})

        face_head = rois["avatar_face_head"]
        avatar_full = rois["avatar_full"]
        avatar_wide = rois["avatar_wide"]
        speech = rois["speech_bubble"]

        self.assertEqual(face_head["kind"], "avatar")
        self.assertTrue(face_head["counts_as_avatar_motion"])
        self.assertTrue(face_head["expected_for_pass"])
        self.assertEqual(avatar_full["kind"], "avatar")
        self.assertTrue(avatar_full["counts_as_avatar_motion"])
        self.assertFalse(avatar_full["expected_for_pass"])
        self.assertEqual(avatar_wide["kind"], "diagnostic")
        self.assertFalse(avatar_wide["expected_for_pass"])
        self.assertEqual(speech["kind"], "guard_ui")
        self.assertFalse(speech["counts_as_avatar_motion"])
        self.assertFalse(speech["expected_for_pass"])
        self.assertIn("semantic_expression_correctness", catalog["future_scenarios"])
        self.assertNotIn("expression", catalog["future_scenarios"])

    def test_expression_visible_browser_helper_uses_thought_core_shape(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        capture_source = (repo_root / "scripts" / "capture-self-mirror-frames.mjs").read_text(encoding="utf-8")
        proof_source = (repo_root / "scripts" / "run-self-mirror-proof.ps1").read_text(encoding="utf-8")

        self.assertIn('"expression-visible"', capture_source)
        self.assertIn("motion.thought_core.expression_visible.v0", capture_source)
        self.assertIn("motion.runtime.vrm_expression_weights.v0", capture_source)
        self.assertIn("expected_roi: \"avatar_face_head\"", capture_source)
        self.assertIn('track_mask: { scope: "face_head", channels: ["expression_weight"] }', capture_source)
        self.assertIn("readProjectionVisualDiagnostics(page)", capture_source)
        self.assertIn("projection_visual_diagnostics: projectionVisualDiagnostics", capture_source)
        self.assertIn('"expression-visible"', proof_source)
        self.assertIn('("none", "context-nod", "dance", "expression-visible")', proof_source)
        self.assertIn('Set-JsonObjectProperty -Object $config -Name "projection_visual_diagnostics"', proof_source)

    def test_browser_helper_preserves_distinct_runtime_and_driver_result_ids(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        capture_source = (repo_root / "scripts" / "capture-self-mirror-frames.mjs").read_text(encoding="utf-8")
        proof_source = (repo_root / "scripts" / "run-self-mirror-proof.ps1").read_text(encoding="utf-8")

        self.assertIn('[string]$RuntimeResultId = ""', proof_source)
        self.assertIn('("--runtime-result-id", $RuntimeResultId)', proof_source)
        self.assertIn('runtimeResultId: ""', capture_source)
        self.assertIn('arg === "--runtime-result-id"', capture_source)
        self.assertIn('const runtimeResultId = args.runtimeResultId || args.driverResultId;', capture_source)
        self.assertIn('runtime_result_id: runtimeResultId', capture_source)
        self.assertIn('driver_result_id: args.driverResultId', capture_source)
        self.assertIn('const plannedRuntimeResultId = args.runtimeResultId || args.driverResultId;', capture_source)
        self.assertIn('planned_runtime_result_id: plannedRuntimeResultId', capture_source)
        self.assertNotIn('runtime_result_id: args.driverResultId,', capture_source)

    def test_browser_helper_normalizes_lifecycle_absolute_timestamps_to_relative_anchors(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        capture_source = (repo_root / "scripts" / "capture-self-mirror-frames.mjs").read_text(encoding="utf-8")

        self.assertIn("lifecycleTraceRequestIssuedAbsoluteMs(trace)", capture_source)
        self.assertIn('item.state === "request_issued"', capture_source)
        self.assertIn("rawAtMs - baseAbsoluteMs", capture_source)
        self.assertIn("safeBaseRelativeMs + (rawAtMs - baseAbsoluteMs)", capture_source)
        self.assertIn("motion_requested_at_ms: lifecycleTraceAnchorMs(", capture_source)
        self.assertIn('"request_issued"', capture_source)
        self.assertIn('"runtime_accepted"', capture_source)
        self.assertIn('"runtime_started"', capture_source)
        self.assertIn('"result"', capture_source)

    def test_browser_helper_records_capture_target_identity_as_helper_page(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        capture_source = (repo_root / "scripts" / "capture-self-mirror-frames.mjs").read_text(encoding="utf-8")

        self.assertIn('schema_version: "self_mirror_capture_target_identity.v0"', capture_source)
        self.assertIn('capture_surface_kind: "helper_playwright_page"', capture_source)
        self.assertIn("capture_target_url: safeUrl", capture_source)
        self.assertIn("trigger_target_url: safeUrl", capture_source)
        self.assertIn("same_page_or_target: true", capture_source)
        self.assertIn('browser_process_kind: "helper_launched"', capture_source)
        self.assertIn('proof_ceiling: "helper_browser_runtime_only"', capture_source)
        self.assertIn("stimulus_id: args.stimulusId || null", capture_source)
        self.assertIn('target_identity: captureTargetIdentity(args)', capture_source)
        self.assertIn('return "redacted_non_local_url";', capture_source)

    def test_browser_wrapper_propagates_capture_manifest_target_and_stimulus(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        proof_source = (repo_root / "scripts" / "run-self-mirror-proof.ps1").read_text(encoding="utf-8")

        self.assertIn('$captureManifest.PSObject.Properties.Name -contains "target_identity"', proof_source)
        self.assertIn('Set-JsonObjectProperty -Object $config -Name "target_identity"', proof_source)
        self.assertIn('$captureManifest.trigger.PSObject.Properties.Name -contains "stimulus_id"', proof_source)
        self.assertIn('Set-JsonObjectProperty -Object $config -Name "stimulus_id"', proof_source)
        self.assertIn('Set-JsonObjectProperty -Object $config.runtime_join -Name "stimulus_id"', proof_source)

    def test_controlled_chrome_observation_metrics_produce_summary_without_frame_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config = _controlled_chrome_metric_config(
                scenario_id="rr003.visible_motion.dance_visible_motion.controlled_chrome.v0",
                expected_motion="broad_avatar_motion",
                expected_roi_id="avatar_full",
                motion_event_id="mot_evt_controlled_chrome_dance_test",
                stimulus_id="mot_stim_controlled_chrome_voice_dance_please",
                stimulus_instance_id="mot_inst_controlled_chrome_dance_test",
                runtime_result_id="mot_res_controlled_chrome_dance_test",
                driver_result_id="",
                result_reason_code="motion_runtime_vrma_started",
                result_safe_visible_state="motion_started",
            )

            summary, rows = analyze_config(config)
            self_mirror_path, *_rest = write_outputs(summary, rows, root / "out")
            payload = json.loads(self_mirror_path.read_text(encoding="utf-8"))
            serialized = json.dumps(payload, ensure_ascii=False)

            self.assertEqual(summary["result"], "visual-pass")
            self.assertEqual(summary["source_ref"]["kind"], "controlled_chrome_metric_summary")
            self.assertEqual(
                summary["capture"]["target_identity"]["capture_surface_kind"],
                "controlled_chrome_extension_tab",
            )
            self.assertEqual(payload["schema_version"], "self_mirror_metric_summary.v0")
            self.assertEqual(payload["result"], "pass")
            self.assertEqual(payload["source"]["kind"], "controlled_chrome_metric_summary")
            self.assertEqual(payload["run_refs"]["stimulus_id"], "mot_stim_controlled_chrome_voice_dance_please")
            self.assertEqual(payload["run_refs"]["runtime_result_id"], "mot_res_controlled_chrome_dance_test")
            self.assertEqual(payload["capture_target_identity"]["chrome_tab_safe_id"], "chrome_tab_safe_test")
            self.assertEqual(payload["test_observability"], "self_mirror_metric")
            self.assertEqual(payload["observability"]["observability_surface_status"], "present")
            self.assertEqual(payload["observability"]["capture_surface_kind"], "controlled_chrome_extension_tab")
            self.assertEqual(payload["observability"]["browser_process_kind"], "chrome_extension_controlled_user_chrome")
            self.assertTrue(payload["observability"]["same_page_or_target"])
            self.assertEqual(payload["observability"]["proof_ceiling"], "controlled_chrome_self_mirror_summary_only")
            self.assertEqual(payload["observability"]["authority_roi_ids"], ["avatar_full"])
            self.assertEqual(payload["observability"]["guard_roi_ids"], ["speech_bubble"])
            self.assertEqual(payload["observability"]["window_coverage"]["expected_rows"], 8)
            self.assertEqual(payload["observability"]["window_coverage"]["observed_rows"], 8)
            self.assertEqual(payload["observability"]["window_coverage"]["missing_rows"], 0)
            self.assertEqual(payload["observability"]["window_coverage"]["active_sample_count"], 3)
            self.assertTrue(payload["observability"]["diagnostic_artifact"]["included"])
            self.assertTrue(payload["observability"]["diagnostic_artifact"]["support_only"])
            self.assertFalse(payload["observability"]["diagnostic_artifact"]["raw_media_included"])
            self.assertFalse(payload["observability"]["raw_frame_included"])
            self.assertFalse(payload["observability"]["raw_screenshot_included"])
            self.assertFalse(payload["observability"]["provider_payload_included"])
            self.assertFalse(payload["observability"]["home_control_or_device_state_included"])
            self.assertEqual(payload["observability"]["visual_failure_reason_codes"], [])
            self.assertIn("not_physical_display_proof", payload["observability"]["does_not_prove"])
            self.assertEqual(
                payload["controlled_chrome_observation"]["source_kind"],
                "controlled_chrome_metric_summary",
            )
            self.assertFalse(payload["raw_frame_included"])
            self.assertFalse(payload["raw_screenshot_included"])
            self.assertNotIn(str(root), serialized)
            self.assertNotIn("frame_001", serialized)
            self.assertNotIn("http://", serialized)

    def test_controlled_chrome_expression_preserves_distinct_runtime_and_driver_result_ids(self) -> None:
        config = _controlled_chrome_metric_config(
            scenario_id="rr003.visible_motion.expression_visible_change.controlled_chrome.v0",
            expected_motion="face_visible_change",
            expected_roi_id="avatar_face_head",
            motion_event_id="mot_evt_controlled_chrome_expression_test",
            stimulus_id="mot_stim_controlled_chrome_voice_smile_please",
            stimulus_instance_id="mot_inst_controlled_chrome_expression_test",
            runtime_result_id="mot_res_controlled_chrome_expression_test",
            driver_result_id="driver_result_controlled_chrome_expression_test",
            result_reason_code="motion_runtime_expression_frame_queued",
            result_safe_visible_state="expression_change_requested",
        )

        summary, rows = analyze_config(config)
        with tempfile.TemporaryDirectory() as temp_dir:
            self_mirror_path, *_rest = write_outputs(summary, rows, Path(temp_dir) / "out")
            payload = json.loads(self_mirror_path.read_text(encoding="utf-8"))

        self.assertEqual(summary["result"], "visual-pass")
        self.assertEqual(payload["run_refs"]["runtime_result_id"], "mot_res_controlled_chrome_expression_test")
        self.assertEqual(payload["run_refs"]["driver_result_id"], "driver_result_controlled_chrome_expression_test")
        self.assertEqual(payload["run_refs"]["runtime_status"], "started")
        self.assertEqual(payload["run_refs"]["runtime_reason_code"], "motion_runtime_expression_frame_queued")

    def test_controlled_chrome_expression_subthreshold_current_packet_remains_nonpass(self) -> None:
        config = _controlled_chrome_metric_config(
            scenario_id="rr003.visible_motion.expression_visible_change.controlled_chrome.v0",
            expected_motion="face_visible_change",
            expected_roi_id="avatar_face_head",
            motion_event_id="mot_evt_controlled_chrome_expression_subthreshold_test",
            stimulus_id="mot_stim_controlled_chrome_voice_smile_please",
            stimulus_instance_id="mot_inst_controlled_chrome_expression_subthreshold_test",
            runtime_result_id="mot_res_controlled_chrome_expression_subthreshold_test",
            driver_result_id="driver_result_controlled_chrome_expression_subthreshold_test",
            result_reason_code="motion_runtime_expression_frame_queued",
            result_safe_visible_state="expression_change_requested",
        )
        config["thresholds"]["active_motion_min_score"] = 0.12
        config["controlled_chrome_observation"]["roi_window_metrics"] = [
            {"roi_id": "avatar_face_head", "window_id": "pretrigger", "sample_count": 3, "motion_score": 0.0},
            {"roi_id": "avatar_face_head", "window_id": "active", "sample_count": 4, "motion_score": 0.035417},
            {"roi_id": "avatar_face_head", "window_id": "release", "sample_count": 2, "motion_score": 0.035417},
            {"roi_id": "avatar_face_head", "window_id": "settle", "sample_count": 2, "motion_score": 0.0},
        ]
        config["projection_visual_diagnostics"] = {
            "schema_version": "projection_visual_in_page_diagnostics.v0",
            "expression_weight_applied": True,
            "frame_applied_count": 1,
            "last_driver_result": "applied",
            "last_driver_reason_code": "motion_driver_applied",
            "last_safe_visible_state": "expression_changed",
            "same_page_or_target": True,
            "target_identity_match": True,
            "surface_match": True,
        }

        summary, rows = analyze_config(config)
        with tempfile.TemporaryDirectory() as temp_dir:
            self_mirror_path, *_rest = write_outputs(summary, rows, Path(temp_dir) / "out")
            payload = json.loads(self_mirror_path.read_text(encoding="utf-8"))

        avatar = _roi(summary, "avatar_face_head")
        self.assertEqual(summary["result"], "visual-missing-motion")
        self.assertEqual(avatar["pass_label"], "visual-missing-motion")
        self.assertEqual(avatar["active_peak_motion_score"], 0.035417)
        self.assertEqual(summary["thresholds"]["active_motion_min_score"], 0.12)
        self.assertEqual(summary["motion_diagnostics"]["diagnostic_result"], "frame-applied-but-pixel-static")
        self.assertEqual(payload["result"], "fail")
        self.assertEqual(payload["observed_issue"], "visual-missing-motion")
        self.assertFalse(payload["raw_frame_included"])
        self.assertFalse(payload["raw_screenshot_included"])

    def test_controlled_chrome_expression_candidate_profile_keeps_current_packet_nonpass(self) -> None:
        config = _controlled_chrome_metric_config(
            scenario_id="rr003.visible_motion.expression_visible_change.controlled_chrome.profile.v0",
            expected_motion="face_visible_change",
            expected_roi_id="avatar_face_head",
            motion_event_id="mot_evt_controlled_chrome_expression_profile_current_packet_test",
            stimulus_id="mot_stim_controlled_chrome_voice_smile_please",
            stimulus_instance_id="mot_inst_controlled_chrome_expression_profile_current_packet_test",
            runtime_result_id="mot_res_controlled_chrome_expression_profile_current_packet_test",
            driver_result_id="driver_result_controlled_chrome_expression_profile_current_packet_test",
            result_reason_code="motion_runtime_expression_frame_queued",
            result_safe_visible_state="expression_change_requested",
        )
        config["thresholds"]["active_motion_min_score"] = 0.05
        config["thresholds"]["threshold_too_strict_ratio"] = 0.75
        config["controlled_chrome_observation"]["roi_window_metrics"] = [
            {"roi_id": "avatar_face_head", "window_id": "pretrigger", "sample_count": 3, "motion_score": 0.0},
            {"roi_id": "avatar_face_head", "window_id": "active", "sample_count": 4, "motion_score": 0.035417},
            {"roi_id": "avatar_face_head", "window_id": "release", "sample_count": 2, "motion_score": 0.035417},
            {"roi_id": "avatar_face_head", "window_id": "settle", "sample_count": 2, "motion_score": 0.0},
        ]
        config["projection_visual_diagnostics"] = {
            "schema_version": "projection_visual_in_page_diagnostics.v0",
            "expression_weight_applied": True,
            "frame_applied_count": 1,
            "last_driver_result": "applied",
            "last_driver_reason_code": "motion_driver_applied",
            "last_safe_visible_state": "expression_changed",
            "same_page_or_target": True,
            "target_identity_match": True,
            "surface_match": True,
        }

        summary, rows = analyze_config(config)
        with tempfile.TemporaryDirectory() as temp_dir:
            self_mirror_path, *_rest = write_outputs(summary, rows, Path(temp_dir) / "out")
            payload = json.loads(self_mirror_path.read_text(encoding="utf-8"))

        avatar = _roi(summary, "avatar_face_head")
        self.assertEqual(summary["result"], "visual-missing-motion")
        self.assertEqual(avatar["pass_label"], "visual-missing-motion")
        self.assertEqual(summary["thresholds"]["active_motion_min_score"], 0.05)
        self.assertEqual(payload["result"], "fail")

    def test_controlled_chrome_expression_candidate_profile_passes_clearer_delta(self) -> None:
        config = _controlled_chrome_metric_config(
            scenario_id="rr003.visible_motion.expression_visible_change.controlled_chrome.profile.v0",
            expected_motion="face_visible_change",
            expected_roi_id="avatar_face_head",
            motion_event_id="mot_evt_controlled_chrome_expression_profile_clear_delta_test",
            stimulus_id="mot_stim_controlled_chrome_voice_smile_please",
            stimulus_instance_id="mot_inst_controlled_chrome_expression_profile_clear_delta_test",
            runtime_result_id="mot_res_controlled_chrome_expression_profile_clear_delta_test",
            driver_result_id="driver_result_controlled_chrome_expression_profile_clear_delta_test",
            result_reason_code="motion_runtime_expression_frame_queued",
            result_safe_visible_state="expression_change_requested",
        )
        config["thresholds"]["active_motion_min_score"] = 0.05
        config["thresholds"]["threshold_too_strict_ratio"] = 0.75
        config["controlled_chrome_observation"]["roi_window_metrics"] = [
            {"roi_id": "avatar_face_head", "window_id": "pretrigger", "sample_count": 3, "motion_score": 0.0},
            {"roi_id": "avatar_face_head", "window_id": "active", "sample_count": 4, "motion_score": 0.055},
            {"roi_id": "avatar_face_head", "window_id": "release", "sample_count": 2, "motion_score": 0.055},
            {"roi_id": "avatar_face_head", "window_id": "settle", "sample_count": 2, "motion_score": 0.0},
        ]
        config["projection_visual_diagnostics"] = {
            "schema_version": "projection_visual_in_page_diagnostics.v0",
            "expression_weight_applied": True,
            "frame_applied_count": 1,
            "last_driver_result": "applied",
            "last_driver_reason_code": "motion_driver_applied",
            "last_safe_visible_state": "expression_changed",
            "same_page_or_target": True,
            "target_identity_match": True,
            "surface_match": True,
        }

        summary, rows = analyze_config(config)
        with tempfile.TemporaryDirectory() as temp_dir:
            self_mirror_path, *_rest = write_outputs(summary, rows, Path(temp_dir) / "out")
            payload = json.loads(self_mirror_path.read_text(encoding="utf-8"))

        avatar = _roi(summary, "avatar_face_head")
        self.assertEqual(summary["result"], "visual-pass")
        self.assertEqual(avatar["pass_label"], "visual-motion-detected")
        self.assertEqual(summary["thresholds"]["active_motion_min_score"], 0.05)
        self.assertEqual(summary["motion_diagnostics"]["diagnostic_result"], "event-correlated-motion")
        self.assertEqual(payload["result"], "pass")
        self.assertIn("not_expression_semantic_proof", payload["does_not_prove"])

    def test_controlled_chrome_observation_rejects_raw_media_flags(self) -> None:
        config = _controlled_chrome_metric_config(
            scenario_id="rr003.visible_motion.dance_visible_motion.controlled_chrome.v0",
            expected_motion="broad_avatar_motion",
            expected_roi_id="avatar_full",
            motion_event_id="mot_evt_controlled_chrome_raw_flag_test",
            stimulus_id="mot_stim_controlled_chrome_raw_flag_test",
            stimulus_instance_id="mot_inst_controlled_chrome_raw_flag_test",
            runtime_result_id="mot_res_controlled_chrome_raw_flag_test",
            driver_result_id="",
            result_reason_code="motion_runtime_vrma_started",
            result_safe_visible_state="motion_started",
        )
        config["controlled_chrome_observation"]["raw_screenshot_included"] = True

        with self.assertRaisesRegex(ValueError, "summary-only"):
            analyze_config(config)

    def test_roi_calibration_keeps_guard_and_face_head_boundaries_explicit(self) -> None:
        catalog_path = Path(__file__).resolve().parents[1] / "self-mirror-scenarios.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))

        for scenario_key in ("context_nod", "dance_visible_motion", "idle_baseline"):
            with self.subTest(scenario_key=scenario_key):
                scenario = catalog["scenarios"][scenario_key]
                rois = {str(roi["roi_id"]): roi for roi in scenario["rois"]}
                speech = rois["speech_bubble"]
                face_head = rois["avatar_face_head"]

                self.assertEqual(speech["kind"], "guard_ui")
                self.assertFalse(speech["counts_as_avatar_motion"])
                self.assertFalse(speech["expected_for_pass"])
                self.assertGreaterEqual(float(speech["rect_norm"]["h"]), 0.38)
                self.assertEqual(face_head["kind"], "avatar")
                self.assertTrue(face_head["counts_as_avatar_motion"])
                self.assertFalse(face_head["expected_for_pass"])
                self.assertNotIn("avatar_face_head", scenario["expected_avatar_roi_ids"])
                self.assertNotIn("avatar_face_head", scenario["synthetic_fixture"]["avatar_motion_roi_ids"])

        dance_rois = {
            str(roi["roi_id"]): roi
            for roi in catalog["scenarios"]["dance_visible_motion"]["rois"]
        }
        avatar_full = dance_rois["avatar_full"]["rect_norm"]
        torso = dance_rois["avatar_torso"]["rect_norm"]
        left_arm = dance_rois["avatar_left_arm"]["rect_norm"]
        right_arm = dance_rois["avatar_right_arm"]["rect_norm"]
        right_hud = dance_rois["right_hud"]["rect_norm"]
        input_bar = dance_rois["input_bar"]["rect_norm"]

        self.assertGreaterEqual(float(avatar_full["w"]), 0.40)
        self.assertLessEqual(float(avatar_full["x"]) + float(avatar_full["w"]), float(right_hud["x"]))
        self.assertLessEqual(float(avatar_full["y"]) + float(avatar_full["h"]), float(input_bar["y"]))
        self.assertGreaterEqual(float(left_arm["w"]), 0.17)
        self.assertGreaterEqual(float(right_arm["w"]), 0.17)
        self.assertLessEqual(float(right_arm["x"]) + float(right_arm["w"]), float(right_hud["x"]))
        self.assertGreaterEqual(float(torso["x"]) + float(torso["w"]) / 2.0, 0.60)

    def test_expression_visible_change_synthetic_fixture_produces_summary_pass(self) -> None:
        catalog_path = Path(__file__).resolve().parents[1] / "self-mirror-scenarios.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        scenario = catalog["scenarios"]["expression_visible_change"]
        windows = [
            {"window_id": "pretrigger", "start_ms": 0, "end_ms": 500},
            {"window_id": "active", "start_ms": 500, "end_ms": 2300},
            {"window_id": "release", "start_ms": 2300, "end_ms": 3500},
            {"window_id": "late_watch", "start_ms": 3500, "end_ms": 8500},
            {"window_id": "settle", "start_ms": 8500, "end_ms": 9000},
        ]
        summary, rows = analyze_config(
            {
                "analysis_run_id": "vismot_run_test_expression_visible_synthetic_001",
                "scenario_id": scenario["scenario_id"],
                "motion_event_id": "mot_evt_test_expression_visible_001",
                "stimulus_instance_id": "mot_inst_test_expression_visible_001",
                "driver_result_id": "mot_res_test_expression_visible_001",
                "proof_layer": "no_live_runtime",
                "scenario": {
                    "scenario_key": scenario["scenario_key"],
                    "label": scenario["label"],
                    "expected_motion": scenario["expected_motion"],
                    "runtime_join_required": scenario["runtime_join_required"],
                },
                "sampling": {"sample_rate_fps": 10},
                "windows": windows,
                "rois": scenario["rois"],
                "thresholds": scenario["thresholds"],
                "synthetic_fixture": {
                    **scenario["synthetic_fixture"],
                    "frame_count": 92,
                    "width": 640,
                    "height": 360,
                },
                "source_ref": {"kind": "synthetic_test_frames", "source_ref_id": "redacted_expression_visible_synthetic"},
                "event_timeline": {
                    "user_request_at_ms": 0,
                    "motion_requested_at_ms": 500,
                    "bridge_dispatched_at_ms": 550,
                    "runtime_started_at_ms": 600,
                    "capture_started_at_ms": 0,
                    "capture_ended_at_ms": 9000,
                },
            }
        )
        self.assertEqual(summary["result"], "visual-pass")
        self.assertEqual(summary["scenario"]["expected_motion"], "face_visible_change")
        self.assertEqual(summary["motion_diagnostics"]["diagnostic_result"], "event-correlated-motion")
        self.assertEqual(summary["motion_diagnostics"]["expected_roi_motion_ids"], ["avatar_face_head"])
        self.assertFalse(summary["motion_diagnostics"]["pass_authority_from_diagnostic_roi"])
        self.assertEqual(_roi(summary, "avatar_face_head")["pass_label"], "visual-motion-detected")
        self.assertEqual(_roi(summary, "speech_bubble")["pass_label"], "guard-ui-motion-excluded")
        self.assertTrue(any(row["roi_id"] == "avatar_face_head" for row in rows))


def _frame() -> np.ndarray:
    return np.zeros((64, 64, 3), dtype=np.uint8)


def _roi(summary: dict[str, object], roi_id: str) -> dict[str, object]:
    for row in summary["roi_results"]:  # type: ignore[index]
        if row["roi_id"] == roi_id:
            return row
    raise AssertionError(f"ROI not found: {roi_id}")


def _controlled_chrome_metric_config(
    *,
    scenario_id: str,
    expected_motion: str,
    expected_roi_id: str,
    motion_event_id: str,
    stimulus_id: str,
    stimulus_instance_id: str,
    runtime_result_id: str,
    driver_result_id: str,
    result_reason_code: str,
    result_safe_visible_state: str,
) -> dict:
    windows = [
        {"window_id": "pretrigger", "start_ms": 0, "end_ms": 300},
        {"window_id": "active", "start_ms": 300, "end_ms": 900},
        {"window_id": "release", "start_ms": 900, "end_ms": 1200},
        {"window_id": "settle", "start_ms": 1200, "end_ms": 1600},
    ]
    rois = [
        {
            "roi_id": expected_roi_id,
            "kind": "avatar",
            "counts_as_avatar_motion": True,
            "expected_for_pass": True,
            "rect_norm": {"x": 0.2, "y": 0.15, "w": 0.3, "h": 0.6},
        },
        {
            "roi_id": "speech_bubble",
            "kind": "guard_ui",
            "counts_as_avatar_motion": False,
            "expected_for_pass": False,
            "rect_norm": {"x": 0.55, "y": 0.05, "w": 0.35, "h": 0.35},
        },
    ]
    roi_window_metrics = [
        {"roi_id": expected_roi_id, "window_id": "pretrigger", "sample_count": 2, "motion_score": 0.0},
        {"roi_id": expected_roi_id, "window_id": "active", "sample_count": 3, "motion_score": 0.42},
        {"roi_id": expected_roi_id, "window_id": "release", "sample_count": 2, "motion_score": 0.02},
        {"roi_id": expected_roi_id, "window_id": "settle", "sample_count": 2, "motion_score": 0.0},
        {"roi_id": "speech_bubble", "window_id": "pretrigger", "sample_count": 2, "motion_score": 0.0},
        {"roi_id": "speech_bubble", "window_id": "active", "sample_count": 3, "motion_score": 0.0},
        {"roi_id": "speech_bubble", "window_id": "release", "sample_count": 2, "motion_score": 0.0},
        {"roi_id": "speech_bubble", "window_id": "settle", "sample_count": 2, "motion_score": 0.0},
    ]
    runtime_join = {
        "motion_event_id": motion_event_id,
        "stimulus_id": stimulus_id,
        "stimulus_instance_id": stimulus_instance_id,
        "runtime_result_id": runtime_result_id,
        "result_status": "started",
        "result_reason_code": result_reason_code,
        "result_safe_visible_state": result_safe_visible_state,
    }
    if driver_result_id:
        runtime_join["driver_result_id"] = driver_result_id
    return {
        "analysis_run_id": f"vismot_run_{stimulus_instance_id}",
        "scenario_id": scenario_id,
        "scenario": {
            "scenario_key": scenario_id,
            "label": scenario_id,
            "expected_motion": expected_motion,
            "runtime_join_required": True,
        },
        "proof_layer": "visible_motion",
        "motion_event_id": motion_event_id,
        "stimulus_id": stimulus_id,
        "stimulus_instance_id": stimulus_instance_id,
        "driver_result_id": driver_result_id,
        "source_ref": {
            "kind": "controlled_chrome_metric_summary",
            "source_ref_id": "redacted_controlled_chrome_tab_safe_test",
        },
        "sampling": {"sample_rate_fps": 8},
        "windows": windows,
        "rois": rois,
        "thresholds": {
            "active_motion_min_score": 0.12,
            "settle_motion_max_score": 0.05,
            "min_consecutive_samples": 2,
        },
        "runtime_join": runtime_join,
        "event_timeline": {
            "motion_requested_at_ms": 300,
            "runtime_started_at_ms": 330,
        },
        "controlled_chrome_observation": {
            "schema_version": "self_mirror_controlled_chrome_observation.v0",
            "target_identity": {
                "schema_version": "self_mirror_capture_target_identity.v0",
                "capture_surface_kind": "controlled_chrome_extension_tab",
                "chrome_tab_safe_id": "chrome_tab_safe_test",
                "same_page_or_target": True,
                "browser_process_kind": "chrome_extension_controlled_user_chrome",
                "proof_ceiling": "controlled_chrome_self_mirror_summary_only",
                "capture_target_url": "http://127.0.0.1/private-redacted-route",
            },
            "viewport": {"width": 1280, "height": 720},
            "roi_window_metrics": roi_window_metrics,
            "raw_frame_included": False,
            "raw_screenshot_included": False,
            "raw_video_included": False,
            "raw_log_included": False,
            "provider_payload_included": False,
            "cleanup_status": {
                "browser_target_finalized": True,
                "runtime_stopped": True,
                "raw_frames_deleted": True,
            },
        },
    }


if __name__ == "__main__":
    unittest.main()
