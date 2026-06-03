from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from statistics import mean
from typing import Any

import cv2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate room-light state from a local video without exporting frames.")
    parser.add_argument("--video", required=True, help="Local video path. The path is not included in output.")
    parser.add_argument("--sample-id", required=True)
    parser.add_argument("--expected-electric-state", choices=["on", "off"], required=True)
    parser.add_argument("--processor-src", required=True)
    parser.add_argument("--windows", type=int, default=5)
    parser.add_argument(
        "--sampling-mode",
        choices=["windows", "all-frames"],
        default="windows",
        help="windows keeps the historical representative-window sample; all-frames evaluates each possible frame-pair start.",
    )
    parser.add_argument(
        "--frame-step",
        type=int,
        default=1,
        help="Frame-start stride for all-frames mode. 1 evaluates every possible pair start.",
    )
    parser.add_argument("--include-feature-summary", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def summarize_numbers(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {"min": None, "max": None, "mean": None}
    return {
        "min": round(min(values), 4),
        "max": round(max(values), 4),
        "mean": round(mean(values), 4),
    }


def increment(counter: dict[str, int], key: str) -> None:
    counter[key] = counter.get(key, 0) + 1


def import_processor(processor_src: Path) -> Any:
    resolved = processor_src.resolve()
    if not resolved.exists():
        raise RuntimeError("processor source path is missing")
    sys.path.insert(0, str(resolved))
    from vision_snapshot_processor.processors.room_light import RoomLightSnapshotProcessor

    return RoomLightSnapshotProcessor


def read_frame(capture: cv2.VideoCapture, frame_index: int) -> Any:
    capture.set(cv2.CAP_PROP_POS_FRAMES, max(0, frame_index))
    ok, frame = capture.read()
    if not ok:
        return None
    return frame


def select_window_starts(
    *,
    total_frames: int,
    frame_gap: int,
    requested_windows: int,
    sampling_mode: str,
    frame_step: int,
) -> list[int]:
    if total_frames <= 2:
        return [0]

    max_start = max(0, total_frames - 1 - frame_gap)
    if sampling_mode == "all-frames":
        step = max(1, int(frame_step))
        return list(range(0, max_start + 1, step))

    if requested_windows == 1:
        return [max_start // 2]
    return sorted({int(round(i * max_start / (requested_windows - 1))) for i in range(requested_windows)})


def main() -> int:
    args = parse_args()
    video_path = Path(args.video)
    if not video_path.exists():
        raise RuntimeError("video file is missing")

    RoomLightSnapshotProcessor = import_processor(Path(args.processor_src))

    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise RuntimeError("video file could not be opened")

    total_frames = int(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    fps = float(capture.get(cv2.CAP_PROP_FPS) or 0.0)
    if total_frames <= 0:
        raise RuntimeError("video has no readable frames")
    if not math.isfinite(fps) or fps <= 0:
        fps = 30.0

    requested_windows = max(1, int(args.windows))
    frame_gap = max(1, int(round(fps * 0.2)))
    frame_step = max(1, int(args.frame_step))
    window_starts = select_window_starts(
        total_frames=total_frames,
        frame_gap=frame_gap,
        requested_windows=requested_windows,
        sampling_mode=str(args.sampling_mode),
        frame_step=frame_step,
    )
    state_counts: dict[str, int] = {}
    lighting_type_counts: dict[str, int] = {}
    daylight_state_counts: dict[str, int] = {}
    electric_probabilities: list[float] = []
    daylight_probabilities: list[float] = []
    dark_probabilities: list[float] = []
    confidences: list[float] = []
    feature_values: dict[str, list[float]] = {}
    evaluated_windows = 0
    skipped_windows = 0

    for index, start in enumerate(window_starts):
        first_frame = read_frame(capture, start)
        second_frame = read_frame(capture, min(total_frames - 1, start + frame_gap))
        if first_frame is None or second_frame is None:
            skipped_windows += 1
            continue

        processor = RoomLightSnapshotProcessor(min_frames=2, window_ms=1000)
        first_stamp = float(start) / fps
        second_stamp = float(min(total_frames - 1, start + frame_gap)) / fps
        processor.observe(first_frame, frame_id=(index * 2) + 1, stamp=first_stamp)
        state = processor.observe(second_frame, frame_id=(index * 2) + 2, stamp=second_stamp)
        if state is None:
            skipped_windows += 1
            continue
        payload = state.to_payload()
        evaluated_windows += 1
        increment(state_counts, str(payload["electric_light"]["state"]))
        increment(lighting_type_counts, str(payload["lighting_type"]))
        increment(daylight_state_counts, str(payload["daylight"]["state"]))
        electric_probabilities.append(float(payload["electric_light"]["probability"]))
        daylight_probabilities.append(float(payload["daylight"]["probability"]))
        dark_probabilities.append(float(payload["probabilities"]["dark"]))
        confidences.append(float(payload["confidence"]))
        for key, value in dict(payload["evidence"]["features"]).items():
            try:
                feature_values.setdefault(str(key), []).append(float(value))
            except (TypeError, ValueError):
                continue

    capture.release()

    expected = args.expected_electric_state
    expected_count = state_counts.get(expected, 0)
    opposite = "off" if expected == "on" else "on"
    opposite_count = state_counts.get(opposite, 0)
    expected_share = expected_count / evaluated_windows if evaluated_windows else 0.0
    opposite_share = opposite_count / evaluated_windows if evaluated_windows else 0.0
    if evaluated_windows <= 0:
        classification = "blocked"
    elif expected_share >= 0.8 and opposite_share <= 0.2:
        classification = "pass"
    elif expected_count > 0:
        classification = "partial"
    else:
        classification = "fail"

    result = {
        "sample_id": args.sample_id,
        "expected_electric_state": expected,
        "classification": classification,
        "sampling_mode": args.sampling_mode,
        "frame_step": frame_step,
        "total_frames": total_frames,
        "fps": round(fps, 4),
        "frame_gap": frame_gap,
        "sampled_window_starts": len(window_starts),
        "requested_windows": requested_windows,
        "evaluated_windows": evaluated_windows,
        "skipped_windows": skipped_windows,
        "electric_state_counts": state_counts,
        "lighting_type_counts": lighting_type_counts,
        "daylight_state_counts": daylight_state_counts,
        "expected_state_share": round(expected_share, 4),
        "opposite_state_share": round(opposite_share, 4),
        "probability_summary": {
            "electric_on": summarize_numbers(electric_probabilities),
            "daylight_present": summarize_numbers(daylight_probabilities),
            "dark": summarize_numbers(dark_probabilities),
            "confidence": summarize_numbers(confidences),
        },
        "raw_media_shared": False,
        "raw_frames_shared": False,
        "raw_screenshot_shared": False,
        "generated_model_written": False,
        "generated_frames_written": False,
    }
    if args.include_feature_summary:
        result["feature_summary"] = {key: summarize_numbers(values) for key, values in sorted(feature_values.items())}

    print(json.dumps(result, ensure_ascii=False, indent=2 if args.json else None))
    return 0 if classification != "blocked" else 2


if __name__ == "__main__":
    raise SystemExit(main())
