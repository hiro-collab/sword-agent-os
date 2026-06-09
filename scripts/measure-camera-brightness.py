from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from typing import Any


def _backend_id(name: str) -> int:
    import cv2

    normalized = name.lower()
    if normalized == "dshow":
        return cv2.CAP_DSHOW
    if normalized == "msmf":
        return cv2.CAP_MSMF
    return 0


def _percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return float(values[0])
    sorted_values = sorted(values)
    position = (len(sorted_values) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(sorted_values) - 1)
    weight = position - lower
    return float(sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight)


def _emit(payload: dict[str, Any], exit_code: int) -> None:
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    raise SystemExit(exit_code)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Read a camera briefly and emit redacted brightness metrics without saving frames."
    )
    parser.add_argument("--camera-index", type=int, default=0)
    parser.add_argument("--backend", choices=["auto", "dshow", "msmf"], default="auto")
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--warmup", type=int, default=10)
    parser.add_argument("--frames", type=int, default=20)
    parser.add_argument("--settle-ms", type=int, default=0)
    args = parser.parse_args()

    try:
        import cv2
    except Exception as exc:  # pragma: no cover - depends on local environment
        _emit(
            {
                "ok": False,
                "error_kind": "opencv_unavailable",
                "detail": exc.__class__.__name__,
                "raw_media_saved": False,
                "raw_media_shared": False,
            },
            2,
        )

    if args.settle_ms > 0:
        time.sleep(args.settle_ms / 1000.0)

    backend = _backend_id(args.backend)
    capture = cv2.VideoCapture(args.camera_index, backend) if backend else cv2.VideoCapture(args.camera_index)
    try:
        if args.width > 0:
            capture.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
        if args.height > 0:
            capture.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
        if args.fps > 0:
            capture.set(cv2.CAP_PROP_FPS, args.fps)

        if not capture.isOpened():
            _emit(
                {
                    "ok": False,
                    "opened": False,
                    "read_frame": False,
                    "backend": args.backend,
                    "camera_index": args.camera_index,
                    "error_kind": "camera_open_failed",
                    "raw_media_saved": False,
                    "raw_media_shared": False,
                },
                3,
            )

        for _ in range(max(0, args.warmup)):
            capture.read()

        means: list[float] = []
        shape: list[int] | None = None
        for _ in range(max(1, args.frames)):
            ok, frame = capture.read()
            if not ok or frame is None:
                continue
            if shape is None:
                shape = [int(value) for value in frame.shape]
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            means.append(float(gray.mean()))

        if not means:
            _emit(
                {
                    "ok": False,
                    "opened": True,
                    "read_frame": False,
                    "backend": args.backend,
                    "camera_index": args.camera_index,
                    "error_kind": "frame_read_failed",
                    "raw_media_saved": False,
                    "raw_media_shared": False,
                },
                4,
            )

        payload = {
            "ok": True,
            "opened": True,
            "read_frame": True,
            "backend": args.backend,
            "camera_index": args.camera_index,
            "frames_used": len(means),
            "shape": shape,
            "mean_brightness": round(float(statistics.fmean(means)), 3),
            "median_brightness": round(float(statistics.median(means)), 3),
            "p10_brightness": round(_percentile(means, 0.10), 3),
            "p90_brightness": round(_percentile(means, 0.90), 3),
            "raw_media_saved": False,
            "raw_media_shared": False,
        }
        _emit(payload, 0)
    finally:
        capture.release()


if __name__ == "__main__":
    main()
