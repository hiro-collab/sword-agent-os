# Architecture Decisions

<!-- architecture-decisions:overview -->

Use this directory for durable product architecture decisions that should not
live only in coordination messages or review threads.

An architecture decision record is appropriate when a decision changes how
operators, developers, or review threads should understand the product shape.
Temporary task routing, private handoffs, raw validation logs, or role messages
belong in the workspace coordination repository instead.

## Minimal Record Shape

<!-- architecture-decisions:template -->

```md
# ADR-YYYYMMDD-short-title

## Status

proposed | accepted | superseded

## Context

What problem, user journey, or maintenance risk forced the decision?

## Decision

What structure, boundary, or convention changes?

## Consequences

What gets easier, what remains limited, and what should not be inferred?
```

Keep records short. Link the product docs that implement the decision.
