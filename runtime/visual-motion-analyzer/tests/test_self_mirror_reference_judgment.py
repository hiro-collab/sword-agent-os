from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from self_mirror_visual_analyzer.reference_judgment import (
    attach_auto_judgment,
    judge_metric_summary,
    load_auto_judgment_profile,
    load_reference_case,
)


REPO_ROOT = Path(__file__).resolve().parents[3]
REFERENCE_EXAMPLE = (
    REPO_ROOT
    / "contracts"
    / "self_mirror_reference_case"
    / "examples"
    / "dance_visible_motion.reference.example.json"
)
PROFILE_EXAMPLE = (
    REPO_ROOT
    / "contracts"
    / "self_mirror_auto_judgment_profile"
    / "examples"
    / "dance_visible_motion.profile.example.json"
)


class SelfMirrorReferenceJudgmentTest(unittest.TestCase):
    def test_reference_case_replay_passes_without_human_input(self) -> None:
        reference_case = load_reference_case(REFERENCE_EXAMPLE)
        profile = load_auto_judgment_profile(PROFILE_EXAMPLE)
        summary = _summary_from_reference_case(reference_case)

        judgment = judge_metric_summary(summary, profile, [reference_case])
        attached = attach_auto_judgment(summary, judgment)

        self.assertEqual(judgment["schema_version"], "self_mirror_auto_judgment_result.v0")
        self.assertEqual(judgment["result"], "pass")
        self.assertFalse(judgment["needs_human_review"])
        self.assertEqual(judgment["manual_observation_ref"], "not_collected")
        self.assertFalse(judgment["manual_observation_used"])
        self.assertEqual(attached["auto_judgment_result"], "pass")
        self.assertEqual(attached["reference_profile_id"], profile["profile_id"])
        self.assertIn(reference_case["reference_case_id"], attached["reference_case_refs"])
        self.assertIn("not_human_observation_authority", attached["does_not_prove"])
        self.assertFalse(attached["auto_judgment"]["direct_correction_dispatch"])

    def test_guard_ui_false_positive_is_unclear_not_pass(self) -> None:
        reference_case = load_reference_case(REFERENCE_EXAMPLE)
        profile = load_auto_judgment_profile(PROFILE_EXAMPLE)
        profile = copy.deepcopy(profile)
        profile["thresholds"]["guard_ui_motion_max_score"] = 0.5
        summary = _summary_from_reference_case(reference_case)
        for metric in summary["roi_window_metrics"]:
            if metric["time_window"] == "active" and metric["counts_as_avatar_motion"]:
                metric["movement_score"] = 0.01
                metric["changed_ratio"] = 0.0
            if metric["roi_id"] == "speech_bubble" and metric["time_window"] == "active":
                metric["movement_score"] = 1.0

        judgment = judge_metric_summary(summary, profile, [reference_case])

        self.assertEqual(judgment["result"], "unclear")
        self.assertTrue(judgment["needs_human_review"])
        self.assertIn("guard-motion-dominates-avatar-motion", judgment["reason_codes"])
        self.assertNotEqual(judgment["result"], "pass")

    def test_insufficient_reference_coverage_cannot_pass(self) -> None:
        reference_case = load_reference_case(REFERENCE_EXAMPLE)
        profile = load_auto_judgment_profile(PROFILE_EXAMPLE)
        profile = copy.deepcopy(profile)
        profile["minimum_reference_coverage"]["minimum_reference_cases"] = 2
        summary = _summary_from_reference_case(reference_case)

        judgment = judge_metric_summary(summary, profile, [reference_case])

        self.assertEqual(judgment["result"], "unclear")
        self.assertTrue(judgment["needs_human_review"])
        self.assertIn("insufficient-reference-coverage", judgment["reason_codes"])

    def test_required_false_positive_category_coverage_cannot_silently_pass(self) -> None:
        reference_case = load_reference_case(REFERENCE_EXAMPLE)
        profile = load_auto_judgment_profile(PROFILE_EXAMPLE)
        profile = copy.deepcopy(profile)
        profile["minimum_reference_coverage"]["required_false_positive_categories"] = [
            "layout_shift"
        ]
        summary = _summary_from_reference_case(reference_case)

        judgment = judge_metric_summary(summary, profile, [reference_case])

        self.assertEqual(judgment["result"], "unclear")
        self.assertTrue(judgment["needs_human_review"])
        self.assertIn(
            "reference-false-positive-category-missing:layout_shift",
            judgment["reason_codes"],
        )
        self.assertNotEqual(judgment["result"], "pass")

    def test_matching_summary_id_with_mismatched_run_refs_cannot_pass(self) -> None:
        reference_case = load_reference_case(REFERENCE_EXAMPLE)
        profile = load_auto_judgment_profile(PROFILE_EXAMPLE)
        summary = _summary_from_reference_case(reference_case)
        summary["run_refs"]["runtime_result_id"] = "mot_res_mismatch_pending_001"

        judgment = judge_metric_summary(summary, profile, [reference_case])

        self.assertEqual(judgment["result"], "unclear")
        self.assertTrue(judgment["needs_human_review"])
        self.assertIn("run-ref-mismatch:runtime_result_id", judgment["reason_codes"])

    def test_redaction_rejects_raw_media_paths_and_correction_authority(self) -> None:
        reference_case = load_reference_case(REFERENCE_EXAMPLE)
        unsafe_case = copy.deepcopy(reference_case)
        unsafe_case["metric_summary_ref"]["artifact_label"] = "C:\\Users\\kawai\\private\\frame_001.png"

        profile = load_auto_judgment_profile(PROFILE_EXAMPLE)
        unsafe_profile = copy.deepcopy(profile)
        unsafe_profile["authority_boundary"]["direct_correction_dispatch"] = True

        with tempfile.TemporaryDirectory() as temp_dir:
            unsafe_case_path = Path(temp_dir) / "unsafe_case.json"
            unsafe_profile_path = Path(temp_dir) / "unsafe_profile.json"
            unsafe_case_path.write_text(json.dumps(unsafe_case), encoding="utf-8")
            unsafe_profile_path.write_text(json.dumps(unsafe_profile), encoding="utf-8")

            with self.assertRaises(ValueError):
                load_reference_case(unsafe_case_path)
            with self.assertRaises(ValueError):
                load_auto_judgment_profile(unsafe_profile_path)


def _summary_from_reference_case(reference_case: dict) -> dict:
    metric_summary_ref = reference_case["metric_summary_ref"]
    run_refs = reference_case["run_refs"]
    metrics = []
    for source_metric in reference_case["pretrigger_metrics"]:
        metrics.append(_metric(source_metric, "pretrigger"))
    for source_metric in reference_case["active_window_metrics"]:
        metrics.append(_metric(source_metric, "active"))
    return {
        "schema_version": "self_mirror_metric_summary.v0",
        "summary_id": metric_summary_ref["summary_id"],
        "analysis_run_id": metric_summary_ref["analysis_run_id"],
        "scenario_id": reference_case["scenario_id"],
        "observed_target": "avatar",
        "result": reference_case["expected_result"],
        "confidence": reference_case["confidence"],
        "needs_attention": reference_case["expected_result"] != "pass",
        "needs_human_review": False,
        "run_refs": {
            "motion_event_id": run_refs["motion_event_id"],
            "stimulus_instance_id": run_refs["stimulus_instance_id"],
            "runtime_result_id": run_refs["runtime_result_id"],
            "runtime_status": run_refs["runtime_status"],
            "runtime_reason_code": run_refs["runtime_reason_code"],
        },
        "roi_window_metrics": metrics,
        "does_not_prove": reference_case["does_not_prove"],
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "raw_media_included": False,
    }


def _metric(metric: dict, window_id: str) -> dict:
    return {
        "roi_id": metric["roi_id"],
        "observed_target": "avatar" if metric["counts_as_avatar_motion"] else "projection_visual",
        "time_window": window_id,
        "sample_count": metric["sample_count"],
        "movement_score": metric["movement_score"],
        "changed_ratio": metric["changed_ratio"],
        "confidence": metric["confidence"],
        "raw_frame_included": False,
        "raw_screenshot_included": False,
        "counts_as_avatar_motion": metric["counts_as_avatar_motion"],
        "expected_for_pass": metric["expected_for_pass"],
        "pass_label": metric["pass_label"],
    }


if __name__ == "__main__":
    unittest.main()
