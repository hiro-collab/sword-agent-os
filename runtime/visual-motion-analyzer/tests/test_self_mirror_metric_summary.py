from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from self_mirror_visual_analyzer.visual_motion_analyzer import analyze_frames, write_outputs


WINDOWS = [
    {"window_id": "pretrigger", "start_ms": 0, "end_ms": 100},
    {"window_id": "active", "start_ms": 100, "end_ms": 400},
    {"window_id": "settle", "start_ms": 400, "end_ms": 700},
]

ROIS = [
    {
        "roi_id": "avatar_full",
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


class SelfMirrorMetricSummaryTest(unittest.TestCase):
    def test_summary_is_authority_shape_without_raw_media_or_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frames = [_frame() for _ in range(6)]
            frames[2][10:26, 10:22] = 255
            frames[3][10:26, 12:24] = 255

            visual_summary, rows = analyze_frames(
                frames,
                analysis_run_id="vismot_run_test_self_mirror_summary_001",
                scenario_id="rr003.visible_motion.context_nod.self_mirror.v0",
                motion_event_id="mot_evt_test_self_mirror_summary_001",
                stimulus_instance_id="mot_inst_test_self_mirror_summary_001",
                driver_result_id="mot_drv_test_self_mirror_summary_001",
                sample_rate_fps=10,
                windows=WINDOWS,
                rois=ROIS,
                source_ref_id=str(root / "private" / "frames"),
                event_timeline={
                    "motion_requested_at_ms": 100,
                    "capture_started_at_ms": 0,
                },
            )

            self_mirror_path, *_rest = write_outputs(visual_summary, rows, root / "out")
            payload = json.loads(self_mirror_path.read_text(encoding="utf-8"))
            serialized = json.dumps(payload, ensure_ascii=False)

            self.assertEqual(payload["schema_version"], "self_mirror_metric_summary.v0")
            self.assertEqual(payload["scenario_id"], "rr003.visible_motion.context_nod.self_mirror.v0")
            self.assertEqual(payload["observed_target"], "avatar")
            self.assertIn("run_refs", payload)
            self.assertEqual(payload["run_refs"]["motion_event_id"], "mot_evt_test_self_mirror_summary_001")
            self.assertEqual(payload["run_refs"]["stimulus_instance_id"], "mot_inst_test_self_mirror_summary_001")
            self.assertEqual(payload["run_refs"]["runtime_result_id"], "mot_drv_test_self_mirror_summary_001")
            self.assertEqual(payload["motion_diagnostics"]["schema_version"], "self_mirror_motion_diagnostics.v0")
            self.assertEqual(payload["motion_diagnostics"]["diagnostic_result"], "event-correlated-motion")
            self.assertIn("motion_requested", payload["motion_diagnostics"]["available_anchor_ids"])
            self.assertIn("bridge_dispatched", payload["motion_diagnostics"]["missing_anchor_ids"])
            self.assertFalse(payload["motion_diagnostics"]["anchor_status"]["all_required_available"])
            self.assertFalse(payload["motion_diagnostics"]["anchor_status"]["raw_log_included"])
            self.assertFalse(payload["motion_diagnostics"]["anchor_status"]["raw_provider_payload_included"])
            self.assertEqual(payload["classification"]["diagnostic_result"], "event-correlated-motion")
            self.assertIn("bridge_dispatched", payload["classification"]["missing_anchor_ids"])
            self.assertEqual(payload["latest_state"]["diagnostic_result"], "event-correlated-motion")
            self.assertIn("bridge_dispatched", payload["latest_state"]["missing_anchor_ids"])
            self.assertIn("confidence", payload)
            self.assertGreaterEqual(payload["confidence"], 0.0)
            self.assertLessEqual(payload["confidence"], 1.0)
            self.assertEqual(payload["needs_human_review"], payload["needs_attention"])
            self.assertEqual(payload["timeline_ref"]["artifact"], "visual_motion_roi_timeseries.csv")
            self.assertFalse(payload["timeline_ref"]["authority"])
            self.assertFalse(payload["raw_frame_included"])
            self.assertFalse(payload["raw_screenshot_included"])
            self.assertFalse(payload["raw_media_included"])
            self.assertEqual(payload["activation_sampling"], "event_driven")
            self.assertEqual(payload["evidence_export"], "verification_capture")
            self.assertTrue(payload["observation_policy"]["timeline_export_expected"])
            self.assertEqual(payload["observation_policy"]["shareable_output"], "summary_plus_csv_html_or_jsonl_supporting_views")
            self.assertFalse(payload["observation_policy"]["verification_capture_is_completion_proof"])
            self.assertEqual(payload["needs_attention"], payload["result"] != "pass")
            if payload["needs_attention"]:
                self.assertNotEqual(payload["observed_issue"], "")
            else:
                self.assertEqual(payload["observed_issue"], "")
                self.assertEqual(payload["recommended_correction"], "")
            self.assertTrue(payload["classification"]["recommendation_is_observation_only"])
            self.assertEqual(
                payload["boundary"]["decision_boundary"]["self_mirror_role"],
                "observation_and_evaluation_only",
            )
            self.assertTrue(payload["boundary"]["decision_boundary"]["does_not_decide_correction"])
            self.assertTrue(payload["boundary"]["decision_boundary"]["does_not_execute_correction"])
            self.assertEqual(payload["latest_state"]["schema_version"], "self_mirror_observation.v0")
            self.assertFalse(payload["latest_state"]["raw_frame_included"])
            self.assertFalse(payload["latest_state"]["raw_screenshot_included"])
            self.assertFalse(payload["latest_state"]["raw_video_included"])
            self.assertFalse(payload["latest_state"]["local_path_included"])
            self.assertFalse(payload["latest_state"]["direct_correction_dispatch"])
            self.assertFalse(payload["latest_state"]["retry_authority"])
            self.assertEqual(payload["latest_state"]["consumer_retry_policy_ref"], "consumer_retry_policy")
            self.assertFalse(payload["latest_state"]["durable_memory_by_default"])
            self.assertEqual(payload["latest_observation_ref"], payload["latest_state"]["observation_id"])
            self.assertFalse(payload["consumer_retry_policy"]["self_mirror_is_command_channel"])
            self.assertFalse(payload["consumer_retry_policy"]["self_mirror_retry_authority"])
            self.assertEqual(payload["consumer_retry_policy"]["retry_policy_kind"], "consumer_config_reference")
            self.assertEqual(payload["consumer_retry_policy"]["retry_limit_default"], 2)
            self.assertTrue(payload["consumer_retry_policy"]["retry_limit_configurable"])
            self.assertIn("thought_core.self_mirror_retry.limit", payload["consumer_retry_policy"]["retry_policy_source"])
            self.assertEqual(
                payload["consumer_retry_policy"]["retry_execution_owner"],
                "thought_core_or_output_owner",
            )
            self.assertFalse(payload["consumer_retry_policy"]["external_side_effect_auto_retry_allowed"])
            self.assertEqual(
                payload["consumer_retry_policy"]["applies_to_side_effect_class"],
                "internal_self_display_only",
            )
            self.assertIn("retry_policy_source", payload["consumer_retry_policy"]["required_trace_fields"])
            self.assertIn("failure_pattern", payload["consumer_retry_policy"]["required_trace_fields"])
            self.assertFalse(
                payload["consumer_retry_policy"]["failure_escalation_policy"]["self_mirror_escalation_authority"]
            )
            self.assertEqual(
                payload["consumer_retry_policy"]["failure_escalation_policy"]["one_off_failure_route"],
                "trace_only",
            )
            self.assertEqual(payload["observation_queue"]["schema_version"], "self_mirror_observation_queue.v0")
            self.assertEqual(payload["observation_queue"]["retention"], "bounded_ring_buffer")
            self.assertEqual(len(payload["observation_queue"]["entries"]), 1)
            self.assertLessEqual(len(payload["observation_queue"]["entries"]), payload["observation_queue"]["max_entries"])
            self.assertFalse(payload["observation_queue"]["raw_frame_included"])
            self.assertFalse(payload["observation_queue"]["raw_screenshot_included"])
            self.assertFalse(payload["observation_queue"]["raw_video_included"])
            self.assertFalse(payload["observation_queue"]["local_path_included"])
            self.assertFalse(payload["observation_queue"]["direct_correction_dispatch"])
            self.assertFalse(payload["observation_queue"]["durable_memory_by_default"])
            self.assertEqual(
                payload["observation_queue"]["consumer_retry_policy"]["self_mirror_observation_ref"],
                payload["latest_observation_ref"],
            )
            self.assertEqual(
                payload["observation_queue"]["consumer_retry_policy"]["retry_limit_default"],
                2,
            )
            self.assertTrue(payload["observation_queue"]["consumer_retry_policy"]["retry_limit_configurable"])
            self.assertGreater(len(payload["roi_window_metrics"]), 0)
            for metric in payload["roi_window_metrics"]:
                self.assertIn("roi_id", metric)
                self.assertIn("time_window", metric)
                self.assertIn("sample_count", metric)
                self.assertIn("movement_score", metric)
                self.assertIn("changed_ratio", metric)
                self.assertIn("confidence", metric)
                self.assertFalse(metric["raw_frame_included"])
                self.assertFalse(metric["raw_screenshot_included"])

            self.assertIn("not_environment_vision", payload["does_not_prove"])
            self.assertIn("not_raw_media_proof", payload["does_not_prove"])
            self.assertIn("not_expression_semantic_proof", payload["does_not_prove"])
            self.assertNotIn(str(root), serialized)
            self.assertNotIn("frame_0", serialized)
            self.assertNotIn(".png", serialized)

    def test_face_visible_change_summary_stays_avatar_visual_change_not_semantic_expression(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            windows = [
                {"window_id": "pretrigger", "start_ms": 0, "end_ms": 100},
                {"window_id": "active", "start_ms": 100, "end_ms": 400},
                {"window_id": "release", "start_ms": 400, "end_ms": 600},
                {"window_id": "settle", "start_ms": 600, "end_ms": 800},
            ]
            frames = [_frame() for _ in range(8)]
            frames[2][10:26, 10:22] = 255
            frames[3][10:26, 12:24] = 255

            visual_summary, rows = analyze_frames(
                frames,
                analysis_run_id="vismot_run_test_face_visible_change_summary_001",
                scenario_id="rr003.visible_motion.expression_visible_change.self_mirror.v0",
                motion_event_id="mot_evt_test_face_visible_change_001",
                stimulus_instance_id="mot_inst_test_face_visible_change_001",
                driver_result_id="mot_res_test_face_visible_change_001",
                sample_rate_fps=10,
                windows=windows,
                rois=[
                    {
                        "roi_id": "avatar_face_head",
                        "kind": "avatar",
                        "counts_as_avatar_motion": True,
                        "expected_for_pass": True,
                        "rect_norm": {"x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0},
                    },
                    {
                        "roi_id": "avatar_wide",
                        "kind": "diagnostic",
                        "counts_as_avatar_motion": False,
                        "expected_for_pass": False,
                        "rect_norm": {"x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0},
                    },
                    {
                        "roi_id": "speech_bubble",
                        "kind": "guard_ui",
                        "counts_as_avatar_motion": False,
                        "expected_for_pass": False,
                        "rect_norm": {"x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0},
                    },
                ],
                scenario_key="expression_visible_change",
                scenario_label="Expression visible face/head ROI change",
                expected_motion="face_visible_change",
                event_timeline={
                    "motion_requested_at_ms": 100,
                    "runtime_started_at_ms": 120,
                    "capture_started_at_ms": 0,
                },
            )

            self_mirror_path, *_rest = write_outputs(visual_summary, rows, root / "out")
            payload = json.loads(self_mirror_path.read_text(encoding="utf-8"))

            self.assertEqual(payload["result"], "pass")
            self.assertEqual(payload["observed_target"], "avatar")
            self.assertEqual(payload["scenario"]["scenario_key"], "expression_visible_change")
            self.assertEqual(payload["scenario"]["expected_motion"], "face_visible_change")
            self.assertEqual(payload["motion_diagnostics"]["expected_roi_motion_ids"], ["avatar_face_head"])
            self.assertFalse(payload["motion_diagnostics"]["pass_authority_from_diagnostic_roi"])
            self.assertIn("not_expression_request_or_runtime_result_proof", payload["does_not_prove"])
            self.assertIn("not_expression_semantic_proof", payload["does_not_prove"])
            self.assertFalse(payload["raw_frame_included"])
            self.assertFalse(payload["raw_screenshot_included"])

    def test_missing_face_visible_change_needs_human_review_without_raw_media(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            frames = [_frame() for _ in range(7)]

            visual_summary, rows = analyze_frames(
                frames,
                analysis_run_id="vismot_run_test_face_visible_change_missing_001",
                scenario_id="rr003.visible_motion.expression_visible_change.self_mirror.v0",
                motion_event_id="mot_evt_test_face_visible_change_missing_001",
                stimulus_instance_id="mot_inst_test_face_visible_change_missing_001",
                driver_result_id="mot_res_test_face_visible_change_missing_001",
                sample_rate_fps=10,
                windows=WINDOWS,
                rois=[
                    {
                        "roi_id": "avatar_face_head",
                        "kind": "avatar",
                        "counts_as_avatar_motion": True,
                        "expected_for_pass": True,
                        "rect_norm": {"x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0},
                    },
                    {
                        "roi_id": "avatar_wide",
                        "kind": "diagnostic",
                        "counts_as_avatar_motion": False,
                        "expected_for_pass": False,
                        "rect_norm": {"x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0},
                    },
                ],
                scenario_key="expression_visible_change",
                scenario_label="Expression visible face/head ROI change",
                expected_motion="face_visible_change",
                runtime_join={"runtime_result_id": "mot_res_test_face_visible_change_missing_001", "result_status": "completed"},
                event_timeline={
                    "motion_requested_at_ms": 100,
                    "runtime_started_at_ms": 120,
                    "capture_started_at_ms": 0,
                },
            )

            self_mirror_path, *_rest = write_outputs(visual_summary, rows, root / "out")
            payload = json.loads(self_mirror_path.read_text(encoding="utf-8"))

            self.assertEqual(payload["result"], "fail")
            self.assertTrue(payload["needs_attention"])
            self.assertTrue(payload["needs_human_review"])
            self.assertEqual(payload["observed_issue"], "visual-missing-motion")
            self.assertEqual(payload["motion_diagnostics"]["diagnostic_result"], "runtime-started-no-visible-motion")
            self.assertEqual(payload["motion_diagnostics"]["expected_roi_motion_ids"], [])
            self.assertFalse(payload["raw_media_included"])
            self.assertFalse(payload["observation_queue"]["raw_frame_included"])


def _frame() -> np.ndarray:
    return np.zeros((64, 64, 3), dtype=np.uint8)


if __name__ == "__main__":
    unittest.main()
