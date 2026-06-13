from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
TASK_PROFILE_SCHEMA = ROOT / "contracts/model_routing/task_profile.v0.schema.json"
SELECTION_SCHEMA = ROOT / "contracts/model_routing/model_route_selection.v0.schema.json"
INDEX = ROOT / "manifests/model-routing/task-profiles.index.v0.json"

PROFILE_FILES = (
    ROOT / "control-plane/sword-voice-agent/services/thought-core/model-routing.task-profiles.v0.json",
    ROOT / "runtime/memory-core/model-routing.task-profiles.v0.json",
)

SIDE_EFFECT_GATED = {
    "memory_lifecycle",
    "issue_lifecycle",
    "home_action",
    "live_device",
    "git_or_publication",
}

FINAL_AUTHORITY_NON_CLAIMS = {
    "not_memory_promotion_final_authority",
    "not_current_state_truth",
    "not_issue_lifecycle_final_authority",
    "not_live_action_approval",
    "not_git_or_publication_authority",
    "not_review_ready",
    "not_strict_release",
    "not_rr003_pass",
}


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def task_profile_schema() -> dict[str, Any]:
    return load_json(TASK_PROFILE_SCHEMA)


def selection_schema() -> dict[str, Any]:
    return load_json(SELECTION_SCHEMA)


def task_profile_properties() -> dict[str, Any]:
    return task_profile_schema()["$defs"]["task_profile"]["properties"]


def task_profile_required() -> set[str]:
    return set(task_profile_schema()["$defs"]["task_profile"]["required"])


def enum_for(field: str) -> set[str]:
    return set(task_profile_properties()[field]["enum"])


def runtime_modifier_enum() -> set[str]:
    return set(task_profile_schema()["$defs"]["runtime_modifier"]["enum"])


def validate_profile(profile: dict[str, Any]) -> None:
    required = task_profile_required()
    missing = required - set(profile)
    extra = set(profile) - set(task_profile_properties())
    if missing:
        raise AssertionError(f"missing required fields: {sorted(missing)}")
    if extra:
        raise AssertionError(f"unsupported fields: {sorted(extra)}")
    for field in (
        "input_kind",
        "output_kind",
        "risk_level",
        "privacy_level",
        "latency_target",
        "context_need",
        "reasoning_depth",
        "determinism_required",
        "side_effect",
        "default_route_policy",
        "fallback_policy",
    ):
        if profile[field] not in enum_for(field):
            raise AssertionError(f"unsupported {field}: {profile[field]}")
    modifiers = set(profile["runtime_modifiers"])
    unsupported = modifiers - runtime_modifier_enum()
    if unsupported:
        raise AssertionError(f"unsupported runtime modifiers: {sorted(unsupported)}")
    if profile["proof_authority_allowed"] is not False:
        raise AssertionError("proof_authority_allowed must be false")
    if not profile["non_claims"]:
        raise AssertionError("non_claims must be non-empty")


def validate_profile_file(path: Path) -> list[dict[str, Any]]:
    payload = load_json(path)
    if payload["schema_version"] != "model-routing.task-profiles.v0":
        raise AssertionError(path)
    profiles = payload["profiles"]
    owner = payload["owner_module"]
    seen: set[str] = set()
    for profile in profiles:
        validate_profile(profile)
        if profile["owner_module"] != owner:
            raise AssertionError(f"owner mismatch in {path}")
        task_class = profile["task_class"]
        if task_class in seen:
            raise AssertionError(f"duplicate task_class in {path}: {task_class}")
        seen.add(task_class)
    return profiles


def collect_index_task_classes(index: dict[str, Any]) -> dict[str, str]:
    seen: dict[str, str] = {}
    for entry in index["entries"]:
        for task_class in entry["task_classes"]:
            if task_class in seen:
                raise AssertionError(f"duplicate task_class in central index: {task_class}")
            seen[task_class] = entry["profile_path"]
    return seen


def load_profiles_by_task_class() -> dict[str, dict[str, Any]]:
    profiles: dict[str, dict[str, Any]] = {}
    for path in PROFILE_FILES:
        for profile in validate_profile_file(path):
            task_class = profile["task_class"]
            if task_class in profiles:
                raise AssertionError(f"duplicate task_class: {task_class}")
            profiles[task_class] = profile
    return profiles


def validate_central_index(index: dict[str, Any]) -> None:
    indexed = collect_index_task_classes(index)
    profiles_by_task_class = load_profiles_by_task_class()
    if indexed != {
        task_class: str(path.relative_to(ROOT)).replace("\\", "/")
        for task_class, profile in profiles_by_task_class.items()
        for path in PROFILE_FILES
        if profile in validate_profile_file(path)
    }:
        raise AssertionError("central index does not match module-local profiles")


def _route_for_fallback(policy: str) -> tuple[str, str]:
    if policy == "local_fallback":
        return "local_fallback", "none"
    if policy == "human_review":
        return "human_review", "human_or_policy_required"
    if policy == "fail_closed":
        return "fail_closed", "blocked"
    return "no_llm", "none"


def select_route(profile: dict[str, Any], modifiers: set[str]) -> dict[str, Any]:
    selected_route = "no_llm"
    authority_ceiling = "none"
    provider_allowed = False
    provider_status = "disabled"
    reason_codes = ["default_route_policy"]
    suppressed_modifiers: list[str] = []

    if "privacy_high" in modifiers or profile["privacy_level"] == "secret_forbidden":
        selected_route, authority_ceiling = _route_for_fallback(profile["fallback_policy"])
        provider_status = "held"
        reason_codes = ["privacy_high_suppressed_provider"]
    elif "safety_or_side_effect" in modifiers or profile["side_effect"] in SIDE_EFFECT_GATED:
        selected_route = "human_review" if profile["fallback_policy"] != "fail_closed" else "fail_closed"
        authority_ceiling = "human_or_policy_required" if selected_route == "human_review" else "blocked"
        provider_status = "held"
        reason_codes = ["safety_or_side_effect_owner_gate"]
    elif "provider_unavailable" in modifiers:
        selected_route, authority_ceiling = _route_for_fallback(profile["fallback_policy"])
        provider_status = "unavailable"
        reason_codes = ["provider_unavailable_fallback"]
    elif "deterministic_confident" in modifiers and profile["determinism_required"] in {"high", "must"}:
        selected_route = "no_llm"
        authority_ceiling = "none"
        provider_status = "not_applicable"
        reason_codes = ["deterministic_confident_no_llm"]
    elif {"review_blocker", "repeated_failure"} & modifiers:
        selected_route = "review_advisory"
        authority_ceiling = "advisory_only"
        provider_allowed = True
        provider_status = "enabled"
        reason_codes = ["advisory_escalation"]
    elif "important_or_safety_tag" in modifiers:
        selected_route = "human_review" if profile["owner_module"] == "memory_core" else "review_advisory"
        authority_ceiling = "human_or_policy_required" if selected_route == "human_review" else "advisory_only"
        provider_status = "held" if selected_route == "human_review" else "enabled"
        provider_allowed = selected_route == "review_advisory"
        reason_codes = ["important_or_safety_tag_escalation"]
    elif {"latency_pressure", "cost_pressure"} & modifiers:
        selected_route, authority_ceiling = _route_for_fallback(profile["fallback_policy"])
        provider_status = "held"
        reason_codes = ["latency_or_cost_deescalation"]
    elif profile["default_route_policy"] == "single":
        selected_route = "classifier_advisory" if profile["output_kind"] == "memory_candidate" else "conversation"
        authority_ceiling = "advisory_only" if selected_route == "classifier_advisory" else "none"
        provider_allowed = True
        provider_status = "enabled"
    elif profile["default_route_policy"] == "two_tier":
        selected_route = "review_advisory"
        authority_ceiling = "advisory_only"
        provider_allowed = True
        provider_status = "enabled"
    elif profile["default_route_policy"] == "human_review":
        selected_route = "human_review"
        authority_ceiling = "human_or_policy_required"
        provider_status = "held"

    if not set(profile["runtime_modifiers"]).issuperset(modifiers):
        suppressed_modifiers = sorted(modifiers - set(profile["runtime_modifiers"]))

    return {
        "schema_version": "model_route_selection.v0",
        "selection_id": f"model_sel_{profile['task_class']}_001",
        "task_class": profile["task_class"],
        "task_profile_id": profile["task_profile_id"],
        "owner_module": profile["owner_module"],
        "input_kind": profile["input_kind"],
        "output_kind": profile["output_kind"],
        "selected_route": selected_route,
        "selected_model_route_id": f"route.{selected_route}.v0",
        "provider_allowed": provider_allowed,
        "provider_status": provider_status,
        "applied_modifiers": sorted(modifiers & set(profile["runtime_modifiers"])),
        "suppressed_modifiers": suppressed_modifiers,
        "route_reason_codes": reason_codes,
        "fallback_policy": profile["fallback_policy"],
        "fallback_reason_code": reason_codes[0],
        "authority_ceiling": authority_ceiling,
        "proof_authority_allowed": False,
        "redaction_profile": "model_route_selection_summary_v0",
        "cache_refs": [],
        "evidence_refs": [f"task_profile:{profile['task_profile_id']}"],
        "latency_bucket": "held",
        "cost_bucket": "held",
        "non_claims": list(dict.fromkeys(profile["non_claims"] + ["not_provider_runtime_proof"])),
        "does_not_prove": sorted(FINAL_AUTHORITY_NON_CLAIMS),
        "summary_safety": {
            "raw_prompt_included": False,
            "raw_transcript_included": False,
            "provider_payload_included": False,
            "env_values_included": False,
            "secret_values_included": False,
            "private_path_included": False,
            "ha_or_device_detail_included": False,
            "raw_media_included": False,
            "final_authority_claimed": False,
            "live_or_git_authority_claimed": False
        },
    }


def validate_selection_summary(summary: dict[str, Any]) -> None:
    schema = selection_schema()
    required = set(schema["required"])
    if missing := required - set(summary):
        raise AssertionError(f"selection summary missing fields: {sorted(missing)}")
    if summary["proof_authority_allowed"] is not False:
        raise AssertionError("route selection cannot have proof authority")
    if summary["authority_ceiling"] not in schema["properties"]["authority_ceiling"]["enum"]:
        raise AssertionError("unsupported authority ceiling")
    if summary["selected_route"] not in schema["properties"]["selected_route"]["enum"]:
        raise AssertionError("unsupported selected route")
    for field, value in summary["summary_safety"].items():
        if value is not False:
            raise AssertionError(f"unsafe summary flag true: {field}")


class ModelRoutingProfilesTests(unittest.TestCase):
    def test_contract_schemas_and_profile_files_parse(self) -> None:
        for path in (TASK_PROFILE_SCHEMA, SELECTION_SCHEMA, INDEX, *PROFILE_FILES):
            payload = load_json(path)
            self.assertIsInstance(payload, dict, path)

    def test_profiles_validate_fixed_fields_enums_and_false_authority(self) -> None:
        for path in PROFILE_FILES:
            profiles = validate_profile_file(path)
            self.assertGreaterEqual(len(profiles), 1)
            for profile in profiles:
                self.assertFalse(profile["proof_authority_allowed"])
                self.assertTrue(set(profile["runtime_modifiers"]).issubset(runtime_modifier_enum()))

    def test_central_index_matches_profiles_and_rejects_duplicate_task_class(self) -> None:
        validate_central_index(load_json(INDEX))

        duplicate_index = copy.deepcopy(load_json(INDEX))
        duplicate_index["entries"][1]["task_classes"][0] = duplicate_index["entries"][0]["task_classes"][0]
        with self.assertRaisesRegex(AssertionError, "duplicate task_class"):
            collect_index_task_classes(duplicate_index)

    def test_unsupported_enum_or_freeform_modifier_is_rejected(self) -> None:
        profile = copy.deepcopy(load_profiles_by_task_class()["ordinary_conversation_response"])
        profile["runtime_modifiers"].append("freeform_magic_route")
        with self.assertRaisesRegex(AssertionError, "unsupported runtime modifiers"):
            validate_profile(profile)

        profile = copy.deepcopy(load_profiles_by_task_class()["ordinary_conversation_response"])
        profile["privacy_level"] = "private_everything"
        with self.assertRaisesRegex(AssertionError, "unsupported privacy_level"):
            validate_profile(profile)

    def test_runtime_modifier_precedence_selects_expected_route_and_authority(self) -> None:
        profiles = load_profiles_by_task_class()
        cases = [
            ("ordinary_conversation_response", {"privacy_high"}, "local_fallback", "none", False),
            ("home_action_preview_or_review", {"safety_or_side_effect"}, "human_review", "human_or_policy_required", False),
            ("ordinary_conversation_response", {"provider_unavailable"}, "local_fallback", "none", False),
            ("motion_or_expression_intent", {"deterministic_confident"}, "no_llm", "none", False),
            ("memory_candidate_tag_suggestion", {"important_or_safety_tag"}, "human_review", "human_or_policy_required", False),
            ("ordinary_conversation_response", {"review_blocker"}, "review_advisory", "advisory_only", True),
            ("ordinary_conversation_response", {"repeated_failure"}, "review_advisory", "advisory_only", True),
            ("ordinary_conversation_response", {"latency_pressure"}, "local_fallback", "none", False),
            ("ordinary_conversation_response", {"cost_pressure"}, "local_fallback", "none", False),
        ]
        for task_class, modifiers, selected_route, authority, provider_allowed in cases:
            with self.subTest(task_class=task_class, modifiers=sorted(modifiers)):
                summary = select_route(profiles[task_class], modifiers)
                validate_selection_summary(summary)
                self.assertEqual(summary["selected_route"], selected_route)
                self.assertEqual(summary["authority_ceiling"], authority)
                self.assertEqual(summary["provider_allowed"], provider_allowed)

    def test_route_selection_summary_is_summary_only(self) -> None:
        profile = load_profiles_by_task_class()["ordinary_conversation_response"]
        summary = select_route(profile, {"provider_unavailable"})
        validate_selection_summary(summary)
        serialized = json.dumps(summary, sort_keys=True)

        unsafe_fixture_values = [
            "blocked_source_value_001",
            "blocked_source_value_002",
            "blocked_source_value_003",
            "blocked_source_value_004",
            "blocked_source_value_005",
            "blocked_source_value_006",
            "blocked_source_value_007",
        ]
        for value in unsafe_fixture_values:
            self.assertNotIn(value, serialized)
        self.assertTrue(all(value is False for value in summary["summary_safety"].values()))

    def test_llm_route_cannot_be_final_authority_for_gated_tasks(self) -> None:
        profiles = load_profiles_by_task_class()
        gated_task_classes = [
            "home_action_preview_or_review",
            "memory_promotion_policy",
            "memory_lifecycle_policy",
            "current_state_revalidation_check",
        ]
        for task_class in gated_task_classes:
            with self.subTest(task_class=task_class):
                summary = select_route(profiles[task_class], {"safety_or_side_effect"})
                validate_selection_summary(summary)
                self.assertFalse(summary["proof_authority_allowed"])
                self.assertIn(summary["authority_ceiling"], {"human_or_policy_required", "blocked"})
                self.assertIn("not_rr003_pass", summary["does_not_prove"])
                self.assertIn("not_git_or_publication_authority", summary["does_not_prove"])

        synthetic_final_gate = copy.deepcopy(profiles["memory_lifecycle_policy"])
        synthetic_final_gate["task_class"] = "git_publication_request"
        synthetic_final_gate["task_profile_id"] = "agent_os.git_publication_request.v0"
        synthetic_final_gate["side_effect"] = "git_or_publication"
        synthetic_final_gate["output_kind"] = "proof_status"
        summary = select_route(synthetic_final_gate, {"safety_or_side_effect"})
        validate_selection_summary(summary)
        self.assertIn(summary["authority_ceiling"], {"human_or_policy_required", "blocked"})
        self.assertFalse(summary["provider_allowed"])

    def test_default_routes_do_not_claim_provider_quality_or_memory_commit(self) -> None:
        profiles = load_profiles_by_task_class()

        conversation = select_route(profiles["ordinary_conversation_response"], set())
        validate_selection_summary(conversation)
        self.assertEqual(conversation["selected_route"], "conversation")
        self.assertIn("not_provider_quality_proof", conversation["non_claims"])

        memory_candidate = select_route(profiles["memory_candidate_tag_suggestion"], set())
        validate_selection_summary(memory_candidate)
        self.assertEqual(memory_candidate["selected_route"], "classifier_advisory")
        self.assertEqual(memory_candidate["authority_ceiling"], "advisory_only")
        self.assertIn("not_durable_memory_commit", memory_candidate["non_claims"])


if __name__ == "__main__":
    unittest.main()
