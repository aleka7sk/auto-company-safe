#!/bin/bash
# ============================================================
# Mock engine standing in for the Claude CLI.
# ============================================================
# Injected via CLAUDE_BIN so the whole supervisor can be exercised offline and
# for free. It accepts the same argv shape auto-loop.sh builds and emits JSON in
# the shape extract_cycle_metadata parses (.result, .subtype, .type,
# .total_cost_usd).
#
# It must stay executable. If it is not, resolve_claude_bin silently falls
# through to the real CLI and the test spends the user's subscription quota.
#
# Behaviour is driven by FAKE_CLAUDE_MODE:
#   ok           - writes a valid IN_PROGRESS consensus (default)
#   invalid      - writes a consensus that fails validate_consensus
#   complete     - writes a consensus claiming COMPLETE with all boxes ticked
#   complete_bad - claims COMPLETE with an unticked box (must be rejected)
#   blocked      - writes BLOCKED
#   limit        - prints a usage-limit message and exits non-zero
#   hang         - sleeps past the cycle timeout
#   tamper       - rewrites MISSION.md (the protected-file guard must revert it)
# ============================================================

set -uo pipefail

MODE="${FAKE_CLAUDE_MODE:-ok}"
PROJECT_DIR="${FAKE_CLAUDE_PROJECT_DIR:-$PWD}"
CONSENSUS="$PROJECT_DIR/memories/consensus.md"

prompt=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p) prompt="${2:-}"; shift 2 ;;
        --model|--permission-mode|--output-format|--settings) shift 2 ;;
        *) shift ;;
    esac
done

# auto-loop.sh probes the engine at startup (for the version banner) without -p.
# That call must have no side effects: doing scenario work there would run before the
# loop takes its first protected-file snapshot, and would make a working guard look broken.
if [ -z "$prompt" ]; then
    echo "0.0.0-fake (mock engine)"
    exit 0
fi

# Record the prompt so tests can assert what the model actually received.
mkdir -p "$PROJECT_DIR/logs"
printf '%s' "$prompt" > "$PROJECT_DIR/logs/last-prompt.txt"

emit() {
    printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"result":%s}\n' \
        "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | sed 's/^/"/; s/$/"/')"
}

write_consensus() {
    local status="$1" boxes="$2" evidence="$3"
    mkdir -p "$(dirname "$CONSENSUS")"
    {
        echo "# Auto Company Consensus"
        echo
        echo "## Last Updated"
        date '+%Y-%m-%d %H:%M:%S'
        echo
        echo "## Current Phase"
        echo "Building"
        echo
        echo "## What We Did This Cycle"
        echo "- mock cycle ($MODE)"
        echo
        echo "## Active Projects"
        echo "- mock: in progress"
        echo
        echo "## Acceptance Criteria"
        printf '%s\n' "$boxes"
        echo
        echo "## Completion Status"
        echo "$status"
        echo
        echo "## Completion Evidence"
        echo "$evidence"
        echo
        echo "## Next Action"
        echo "Continue the mock build."
        echo
        echo "## Company State"
        echo "- Product: mock"
        echo
        echo "## Open Questions"
        echo "- none"
    } > "$CONSENSUS"
}

ALL_DONE='- [x] `go build ./...` completes with no errors
- [x] `go test ./...` passes'
PARTIAL='- [x] `go build ./...` completes with no errors
- [ ] `go test ./...` passes'

case "$MODE" in
    ok)
        write_consensus "IN_PROGRESS" "$PARTIAL" "(pending)"
        emit "Advanced one criterion."
        ;;
    invalid)
        mkdir -p "$(dirname "$CONSENSUS")"
        echo "totally malformed, no required headings" > "$CONSENSUS"
        emit "Wrote a malformed consensus."
        ;;
    invalid_both)
        # Corrupt the backup too. This is the deadlock the guard exists for: restoring an
        # invalid backup over an invalid file makes every cycle fail forever.
        mkdir -p "$(dirname "$CONSENSUS")"
        echo "totally malformed, no required headings" > "$CONSENSUS"
        echo "also malformed" > "$CONSENSUS.bak"
        emit "Wrote a malformed consensus and backup."
        ;;
    complete)
        write_consensus "COMPLETE" "$ALL_DONE" 'go build ./... -> ok
go test ./... -> ok (3 tests)'
        emit "Product complete."
        ;;
    complete_bad)
        write_consensus "COMPLETE" "$PARTIAL" "(none)"
        emit "Claiming complete without finishing."
        ;;
    blocked)
        write_consensus "BLOCKED" "$PARTIAL" "(none)"
        emit "Blocked, need a human decision."
        ;;
    limit)
        echo "Claude usage limit reached. Try again later."
        exit 1
        ;;
    hang)
        sleep 3600
        ;;
    tamper)
        echo "**Product:** Hijacked Product" > "$PROJECT_DIR/MISSION.md"
        write_consensus "IN_PROGRESS" "$PARTIAL" "(pending)"
        emit "Rewrote the mission."
        ;;
    *)
        echo "fake-claude: unknown FAKE_CLAUDE_MODE=$MODE" >&2
        exit 2
        ;;
esac
exit 0
