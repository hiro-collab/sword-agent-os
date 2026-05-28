# Approval Queue

Approval Queue is the Agent OS runtime component for review-required behavior.

It is the authority surface for approvals. UI, CLI, voice, chat, avatar, and
other human-facing clients may present or submit approval decisions, but they do
not own the approval model.

## Responsibilities

- Create approval requests with stable `approval_id` values.
- Track pending, approved, denied, expired, cancelled, and superseded approval
  states.
- Preserve target type, requested operation, risk, requester, correlation IDs,
  expiry, approver metadata, and decision trace.
- Support high-risk home actions, protected-memory deletion, policy changes,
  control interventions, and future review-required behavior.
- Allow multiple approval clients without duplicating approval authority.
- Record enough status for event journal, status store, diagnostics, and memory
  episodes.

## Approver Identity

Approval records support approver identity metadata, but the first
implementation must work before person detection or identity classification
exists.

Initial fields:

- `approver_id`
- `approval_method`
- `assurance_level`
- `confirmed_at`
- `second_factor_required`

Early local approvals may use `unknown` or `local_operator` with low assurance.
Future person-detection, authentication, or identity systems may raise
assurance for high-risk operations.

## Policy

Approval requirements are driven by behavior properties such as risk, authority,
agency mode, target domain, and protected status. They are not determined only
by whether something is called an action.

Voice or avatar approval can be useful, but high-risk approval may require
stronger assurance because of speech recognition, impersonation, or context
confusion risks.

## Boundaries

- Approval Queue does not decide action success.
- Approval Queue does not execute home-control operations.
- Approval Queue does not delete memory records.
- Approval Queue records review decisions and exposes state for runtime
  consumers.
- Execution remains with the requesting runtime or organ after policy accepts
  the approval result.
