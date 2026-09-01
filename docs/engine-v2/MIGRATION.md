# Migration from the legacy loop

## Current branch baseline

The existing mission-locked loop remains available as `make start-legacy` during migration.
Engine v2 is additive until its own tests, seeded-bug evaluations and one real project hardening
run pass.

## Migration phases

### Phase 1 — deterministic state and evidence

- compile MISSION.md to immutable JSON;
- use stable criterion IDs;
- cap criteria per slice;
- reject model-authored completion;
- require runtime/browser/owner/verifier evidence;
- block completion on open P0/P1 findings;
- reject ignored untracked product output.

### Phase 2 — role-separated sessions

- product research and architecture are read-only;
- implementation works in an isolated product worktree;
- adversarial testing has tests-only write scope;
- verification has no write tools;
- every Claude call has explicit `--max-turns`, `--max-budget-usd`, `--effort`,
  `--tools`, `--strict-mcp-config` and structured JSON output.

### Phase 3 — external browser supervisor

- start the release-like process outside the coding sandbox;
- run Playwright desktop, phone, multi-tab/session and tenant-isolation scenarios;
- retain trace, screenshots, console/network errors and app logs;
- hash evidence and associate it with a commit.

### Phase 4 — evaluations

Before v2 becomes the default, it must detect seeded failures including:

- cross-tenant foreign references;
- multiple active holds for one request;
- refund above net payment;
- webhook event lost instead of quarantined;
- mobile route unreachable from navigation;
- CSRF invalidation across tabs;
- stale hold after request dates change.

### Phase 5 — switch default

`make start` changes to v2 only after the above passes. The legacy loop remains available for
recovery for one release cycle.
