"""Self Mirror visual analyzer public API."""

from .reference_judgment import attach_auto_judgment, judge_metric_summary
from .summary import build_self_mirror_metric_summary

__all__ = [
    "analyze_config",
    "analyze_frames",
    "attach_auto_judgment",
    "build_self_mirror_metric_summary",
    "judge_metric_summary",
    "main",
    "write_outputs",
]


def __getattr__(name: str):
    if name in {"analyze_config", "analyze_frames", "main", "write_outputs"}:
        from . import visual_motion_analyzer

        return getattr(visual_motion_analyzer, name)
    raise AttributeError(name)
