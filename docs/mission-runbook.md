# Mission Runbook

How to run this fork safely: one fixed product, no account exposure, a stop you can trust,
and an automatic finish when the product is actually done.

## What changed from upstream

Upstream picks its own product and never stops. This fork does neither.

| Area | Upstream | Here |
|---|---|---|
| What to build | Brainstormed in cycle 1, may pivot any time | Fixed in `MISSION.md`, injected first in every prompt |
| Termination | `while true`, no exit condition | Stops on completion, cycle cap, runtime cap, or BLOCKED |
| Enforcement | Prose in `CLAUDE.md`, not even injected into the prompt | OS sandbox + deny rules + PreToolUse hook, via `loop-settings.json` |
| External accounts | `gh` and `wrangler` encouraged | Both blocked. Local-only run |
| Backend stack | Whatever it picks | Go |

## Before the first run

1. **Fill in `MISSION.md`.** Replace `**Product:** TBD` with a real name on that exact
   line, then complete every section. The loop refuses to start while it says TBD, and
   refuses to start without a `## Definition of Done`.

   Write the Definition of Done as objective, checkable statements. Keep the four Go
   gates (`go build`, `go vet`, `go test`, single-command start) — they are what makes
   "done" verifiable rather than a matter of opinion.

2. **Run the tests.** `make test` runs everything offline against a mock engine. It
   spends no quota and touches no network.

3. **Do one supervised cycle.** `MAX_CYCLES=1 make start`, in the foreground, watching.

4. **Inspect properly.** `git status` is blind here — `projects/`, `memories/` and
   `docs/*/` are all gitignored, so the loop's actual output is invisible to it:

   ```bash
   ls -la projects/ memories/ docs/*/
   cat memories/consensus.md
   cat .auto-loop-state
   cat logs/guard-audit.log      # every Bash command the agent attempted
   git status && git diff        # only catches changes to tracked infrastructure
   ```

5. **Check for a silent stall.** `grep -iE 'denied|permission|blocked' logs/cycle-*.log`.
   A sandbox denial the agent cannot work around looks like a successful cycle in the
   loop's own accounting.

Only after all five should you consider `make install` (the launchd daemon). It sets
`RunAtLoad`, so it survives reboots.

## Running

```bash
make start          # foreground, ctrl-c to stop
make status         # loop state, including MISSION_PRODUCT and criteria progress
make monitor        # live logs
make stop           # graceful stop; also kills the in-flight engine
make freeze-status  # summary of the last stop
```

## How it stops

Every exit routes through `terminal_stop`, which writes `memories/freeze/<time>-<reason>/`
containing the consensus, the run state, the mission, the last cycle log, and a `SUMMARY.md`.
It also creates `.auto-loop-paused`, without which launchd would respawn the loop within
30 seconds and the "stop" would be fiction.

| Reason | Trigger |
|---|---|
| `completed` | Every acceptance criterion checked, evidence present, confirmed `REQUIRED_COMPLETE_STREAK` cycles in a row |
| `stopped_cap` | `MAX_CYCLES`, `MAX_RUNTIME_SECONDS`, `STOP_AFTER_CRITERIA`, or too many usage-limit waits |
| `blocked` | The team reported `BLOCKED` for `STOP_ON_BLOCKED` consecutive cycles |
| `stopped` | You ran `make stop` or sent a signal |

Resume with `rm -f .auto-loop-paused && make start`. After a `completed` run the loop
refuses to start again unless you pass `RESET_RUN=1`, which clears the consensus first —
otherwise it would re-read the old COMPLETE consensus, "confirm" it, and stop again having
built nothing.

## Completion is claimed by the model

The bar is: every box in `## Acceptance Criteria` ticked, a `## Completion Evidence`
section containing real `go build` / `go vet` / `go test` output, and the same state
holding across two consecutive fresh sessions. A premature claim is logged as
`[REJECT] COMPLETE rejected: N/M criteria checked` and the run continues.

That raises the cost of a false claim; it does not make one impossible. **Read the freeze
record before you believe it.**

## Go dependencies work differently here

The sandbox proxy and the Go toolchain do not get along: `curl` reaches
`proxy.golang.org` fine through it, but `go mod download` fails with
`tls: failed to verify certificate`. Rather than exempting Go from the sandbox, the agent
builds strictly offline (`GOPROXY=off`) and the supervisor — a plain bash script, not
sandboxed — runs `go mod tidy` and `go mod download` between cycles.

Consequences:

- The agent adds a dependency by writing the `import` statement. `go get` fails by design.
- A build that fails only on a missing module heals itself on the next cycle.
- The agent can never fetch from the network. Only the supervisor can, and only what is
  already imported in the code.

Module and build caches live in `.gocache/` inside the project, because the sandbox only
grants write access there.

## What this does not protect against

- **The sandbox is not a VM.** Anthropic's own docs: "Sandboxing reduces risk but is not
  a complete isolation boundary." TLS is not inspected, so any allowed domain is a
  potential exfiltration path.
- **Command-pattern matching is evadable** — wrappers, generated scripts, `node -e`. The
  deny rules and the hook are tripwires; the OS sandbox is the boundary.
- **The mission lock is instruction, not enforcement.** It makes drifting unlikely and
  visible, not impossible.
- **`make test` proves nothing about security.** It replaces the whole Claude Code
  harness with a mock, and the sandbox, deny rules and hooks are harness features. Only a
  real supervised cycle exercises those.
