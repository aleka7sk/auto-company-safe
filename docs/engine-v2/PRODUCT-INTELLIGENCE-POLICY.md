# Product intelligence and bounded improvement policy

## Why this exists

Blindly implementing a founder prompt is unsafe: prompts often contain premature solutions,
missing constraints, unsupported market claims or scope that does not match the underlying
problem. Ignoring the founder and inventing a different product is equally unsafe.

The engine therefore treats the mission as a hierarchy:

1. founder-stated problem and desired outcome;
2. explicit legal, safety, budget and scope boundaries;
3. verified current product behavior and accepted decisions;
4. proposed requirements and implementation details.

Levels 1–3 are preserved unless the owner explicitly changes them. Level 4 must be challenged.

## Required reasoning for material decisions

For architecture, business model, new user role, sensitive data, permissions, pricing, external
integration or expensive UX change, the responsible read-only agent must:

- state the decision and constraints;
- inspect the existing product and current workaround;
- research current primary sources;
- compare at least three realistic options, including keeping the current approach;
- report evidence against its preferred option;
- identify failure modes, operating cost, migration and rollback;
- mark confidence and unresolved unknowns;
- classify the decision as reversible, costly-to-reverse or irreversible.

The agent must not use popularity, novelty or benchmark rank as the sole justification.

## Improvement classes

### AUTO

May be incorporated into a slice without owner interruption only when all are true:

- directly improves an already approved user outcome;
- is reversible in one local commit;
- adds no new user role, sensitive data, external account or billing behavior;
- does not increase the slice beyond configured file/line/criterion limits;
- adds or strengthens objective acceptance evidence;
- is recorded in the slice decision log.

Examples: a clearer empty state, idempotency key, missing database constraint, visible retry,
keyboard focus or an operator-facing error message.

### NOTIFY

The agent may implement and clearly report a reversible internal choice whose alternatives have
similar product consequences: package boundaries, internal naming, small index, local component
composition or test fixture design.

### OWNER_APPROVAL_REQUIRED

Stop before implementation for changes involving:

- product positioning or target buyer;
- pricing, billing, financial movement or contractual promises;
- user roles or authorization boundaries;
- collection/retention of sensitive or regulated data;
- destructive migration or data deletion;
- external provider commitment;
- public release or production deployment;
- a second product or major scope expansion;
- a costly-to-reverse architecture choice.

## Product-value proposal budget

A discovery or planning run may produce at most three value proposals. Each proposal must include:

- user problem strengthened;
- expected measurable outcome;
- smallest validation;
- implementation cost/risk;
- why it is not already in scope;
- recommendation: now, later, or reject.

Only one AUTO proposal may be incorporated per delivery slice. This prevents "helpful" agents
from quietly turning an MVP into a platform.
