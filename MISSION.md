**Product:** TBD

<!--
  FILL THIS FILE IN BEFORE THE FIRST RUN. The loop refuses to start while Product is TBD.

  This file is the mission lock. It is injected as the FIRST block of every cycle's
  prompt and overrides everything in PROMPT.md and CLAUDE.md. The loop treats it as
  immutable: editing it is denied by loop-settings.json and any change made during a
  cycle is reverted. Change it yourself, with the loop stopped.

  Replace TBD above with a short product name on that exact line — the loop parses it.
-->

## Problem

<!-- One paragraph: the specific pain, for whom, and what they do today instead. -->

## Target User

<!-- One or two sentences. A concrete person, not a segment. -->

## In Scope

<!-- Bullet list. Only what belongs in v1. Everything here should be buildable and testable locally. -->

## Out of Scope

- **Do not build a second product.** One product only, in `projects/<product-slug>/`.
- **Do not copy `projects/snapog/`.** It is a leftover from a previous, unrelated run
  (Cloudflare Workers + TypeScript). It is not the template, not the stack, and not the
  mission. Ignore it entirely.
- **No cloud deployment, no GitHub operations.** This run is local-only: `gh` and
  `wrangler` are blocked. Deployment happens later, by hand, after human review.
- <!-- Add product-specific exclusions here. -->

## Tech Stack

- **Backend: Go** (toolchain go1.26.5). Standard layout: `cmd/` for entrypoints,
  `internal/` for packages. Dependencies via `go.mod`.
- **Dependency workflow is unusual here — read this.** The build runs strictly offline
  (`GOPROXY=off`): the sandbox blocks the Go toolchain from reaching the module proxy.
  To add a dependency, just write the `import` statement. Do not run `go get` — it will
  fail with `module lookup disabled by GOPROXY=off`, and that is expected, not a bug.
  The supervisor runs `go mod tidy` and `go mod download` between cycles, so the module
  becomes available on the next cycle. If a build fails only because of a missing module,
  record it in consensus and continue with other work; it resolves itself next cycle.
- **Storage:** prefer SQLite or plain files for v1. No managed cloud services.
- **Frontend:** <!-- Fill in if the product needs a UI, or write "none for v1". npm is available. -->

## Definition of Done

<!--
  Machine-checkable criteria only. The loop may only declare the product COMPLETE when
  every box here is checked in memories/consensus.md AND it can show the command output
  proving it. Keep these objective — "works well" is not checkable.
  Edit this list to fit the product, but keep the first four.
-->

- [ ] `go build ./...` completes with no errors
- [ ] `go vet ./...` reports nothing
- [ ] `go test ./...` passes, and covers the core business logic
- [ ] The service starts locally with a single documented command
- [ ] `README.md` in the product directory explains what it does, how to run it, and how to test it
- [ ] <!-- Add the product's own acceptance criteria here, one per line. -->
