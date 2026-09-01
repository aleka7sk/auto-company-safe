# Auto Company Engine v2 — Controlled Product Delivery

Status: implementation in progress

## Goal

Turn Auto Company from a large self-checking generation loop into a controlled delivery
runtime. The runtime may use AI judgment for discovery, architecture and implementation,
but the model cannot certify its own completion.

## Principles

1. **Mission is intent, not executable truth.** The engine preserves the founder's problem,
   constraints and explicit exclusions while challenging ambiguous, harmful or premature
   implementation choices.
2. **Research before material commitment.** Material decisions require current primary
   sources, at least three realistic options, evidence against the preferred option, explicit
   trade-offs and reversibility.
3. **Reasonable product improvement.** The agent may add a small reversible improvement when
   it directly strengthens the stated user outcome without introducing a second product,
   external account, sensitive data class, pricing commitment, new role or irreversible
   architecture. Everything else becomes a proposal requiring owner approval.
4. **One bounded vertical slice at a time.** Default maximum: two acceptance criteria,
   twenty changed files and two thousand changed lines.
5. **Separation of powers.** Planner, implementer, adversarial tester, browser runner and
   release verifier use separate sessions, inputs and tool permissions.
6. **Evidence over assertions.** Completion is computed from structured runtime, browser,
   owner and independent-review evidence tied to a specific commit.
7. **No invisible product code.** Product output must be tracked in Git, either in a dedicated
   repository or a nested repository. An ignored untracked `projects/*` directory is rejected.
8. **P0/P1 findings block completion.** Models cannot waive a blocker. Waivers are explicit
   owner records with rationale.

## Pipeline

```text
MISSION.md
  -> mission compiler
  -> discovery (read-only)
  -> opportunity / product contract
  -> architecture options + ADR
  -> UX contract and route-state matrix
  -> bounded slice
  -> isolated worktree
  -> implementation
  -> adversarial tests in a separate context
  -> deterministic command evidence
  -> real browser evidence outside the coding sandbox
  -> independent release verification
  -> owner acceptance
```

## State and contracts

Engine-owned state lives in `.auto-company-v2/`:

```text
.auto-company-v2/
├── config.json
├── state.json
├── contracts/
│   └── mission.json
├── evidence/
├── artifacts/
└── worktrees/
```

The model cannot edit evidence or state directly. It produces code and structured proposals;
the runtime validates and records outcomes.

## Roles

### Product researcher

Read-only. Separates facts, user statements, assumptions, recommendations and unknowns.
Returns evidence for and against the current product hypothesis, current alternatives, the
smallest valuable wedge and no more than five material owner decisions.

### Solution architect

Read-only. Inspects the current code first. For material choices, compares at least three
realistic options across correctness, complexity, operability, cost, migration, failure modes
and rollback. Does not edit production code.

### Implementer

Works on one slice in an isolated worktree. May edit production code and ordinary tests but
cannot edit mission, contracts, evidence, runtime policies or mark acceptance as passed.

### Adversarial tester

Receives requirements and the frozen implementation diff, not the implementer's reasoning.
May add or modify tests/evals only. Its objective is to falsify the acceptance claim with the
smallest counterexample.

### Browser runner

A deterministic supervisor outside the coding sandbox launches the built product on loopback,
runs Playwright scenarios, stores traces/screenshots/network logs, hashes the artifacts and
records browser evidence.

### Release verifier

Read-only. Reviews requirements, diff, runtime evidence, browser evidence, findings and
operational documentation. It can return PASS, FAIL or BLOCKED; it cannot repair code.

## Completion

A criterion passes only when all of its required evidence classes are present. A UI criterion,
for example, defaults to:

```text
runtime_command + browser + independent_review
```

A model-authored Markdown checkbox is ignored. Final completion requires all criteria proven,
no open P0/P1 findings and all manual owner gates resolved.
