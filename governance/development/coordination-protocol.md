# Coordination Protocol

Development coordination is separate from Agent OS runtime communication.

The shared coordination repository is for summarized, shareable development
state only. Thread-private worklogs, raw command output, local paths, secrets,
and scratch data stay in `coordination/local`.

## Shared Message Types

- `notice`: information only
- `request`: asks another thread to do or review something
- `question`: needs a decision or answer
- `blocker`: cannot proceed without help
- `proposal`: suggested design or change
- `decision`: accepted project decision
- `handoff`: work transfer or end-of-thread summary
- `conflict`: edit or responsibility conflict

## Shared Directories

- `registry/`: thread and worktree registry
- `messages/`: active inter-thread messages
- `tasks/`: visible work units assigned to or claimed by threads
- `reservations/`: claimed files, areas, or decisions in progress
- `handoffs/`: thread handoffs
- `decisions/`: accepted decisions
- `shared-notes/`: useful knowledge that is not yet a decision
- `admin/`: coordination-system administration, templates, and process reviews

Tasks are not rigid permission gates. Small related work can happen inside a
thread when needed, but out-of-area or shared-surface work should be mentioned
in the handoff.

`coordination-admin` manages the development coordination system. It routes
technical integration decisions to `integration-main` instead of owning the
Agent OS architecture directly.
