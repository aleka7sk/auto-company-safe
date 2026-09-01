# Auto Company Engine v2

The first deterministic layer of the controlled-delivery runtime.

## What is implemented

- immutable compilation of `MISSION.md` into a structured contract;
- stable acceptance criterion IDs;
- default two-criterion slice cap;
- explicit runtime/browser/owner/verifier evidence classes;
- rejection of evidence certified by the implementation model;
- P0/P1 finding gate;
- completion computed by the runtime rather than Markdown checkboxes;
- mission hash protection;
- doctor check that rejects ignored, untracked product output;
- compact context export with bounded product-improvement policy.

## Build and test

```bash
cd engine-v2
go test ./...
go vet ./...
go build ./cmd/autoco-v2
```

## Initialize

From the Auto Company repository root:

```bash
go run ./engine-v2/cmd/autoco-v2 init \
  --root . \
  --mission MISSION.md \
  --product-root projects/booking-calendar
```

The command writes `.auto-company-v2/`. It deliberately does not trust checked boxes already
present in MISSION.md or consensus.md.

## Inspect and plan a bounded slice

```bash
go run ./engine-v2/cmd/autoco-v2 status --root .
go run ./engine-v2/cmd/autoco-v2 next-slice --root .
go run ./engine-v2/cmd/autoco-v2 export-context --root . --stage implementation
```

## Record evidence

Only the named independent actors are accepted:

```bash
go run ./engine-v2/cmd/autoco-v2 record-evidence \
  --root . --criterion AC-... \
  --kind runtime_command --actor runtime \
  --command 'go test ./...' --exit-code 0 --commit <sha>
```

Browser evidence requires a hashed artifact, owner evidence requires `actor=owner`, and
independent review requires `actor=verifier`.

## Completion

```bash
go run ./engine-v2/cmd/autoco-v2 complete --root .
```

The command exits non-zero until every criterion has all required evidence and no P0/P1 finding
remains open.
