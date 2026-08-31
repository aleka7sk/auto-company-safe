#!/bin/bash
# ============================================================
# Auto Company — 24/7 Autonomous Loop
# ============================================================
# Keeps selected CLI engine (Claude/Codex) running continuously.
# Uses fresh sessions with consensus.md as the relay baton.
#
# Usage:
#   ./auto-loop.sh              # Run in foreground
#   ./auto-loop.sh --daemon     # Run via launchd (macOS only)
#
# Stop:
#   ./stop-loop.sh              # Graceful stop
#   kill $(cat .auto-loop.pid)  # Force stop
#
# Config (env vars):
#   ENGINE=claude               # Engine selection: claude|codex (default: claude)
#   MODEL=...                   # Optional model override (empty = engine default)
#   CLAUDE_BIN=...              # Optional Claude executable override
#   CLAUDE_PERMISSION_MODE=bypassPermissions
#                               # Claude permission mode (default: bypassPermissions)
#   CODEX_BIN=...               # Optional Codex executable override
#   CODEX_SANDBOX_MODE=danger-full-access
#                               # Codex sandbox mode (only for ENGINE=codex)
#   LOOP_INTERVAL=30            # Seconds between cycles (default: 30)
#   CYCLE_TIMEOUT_SECONDS=1800  # Max seconds per cycle before force-kill
#   MAX_CONSECUTIVE_ERRORS=5    # Circuit breaker threshold
#   COOLDOWN_SECONDS=300        # Cooldown after circuit break
#   LIMIT_WAIT_SECONDS=3600     # Wait on usage limit
#   MAX_LOGS=200                # Max cycle logs to keep
#   AUTO_LOOP_PROTECT_GITIGNORE=1
#                               # Restore .gitignore if a cycle mutates it
# ============================================================

set -euo pipefail

# === Resolve project root (always relative to this script) ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LOG_DIR="$PROJECT_DIR/logs"
CONSENSUS_FILE="$PROJECT_DIR/memories/consensus.md"
PROMPT_FILE="$PROJECT_DIR/PROMPT.md"
MISSION_FILE="$PROJECT_DIR/MISSION.md"
LOOP_SETTINGS_FILE="$PROJECT_DIR/loop-settings.json"
PID_FILE="$PROJECT_DIR/.auto-loop.pid"
STATE_FILE="$PROJECT_DIR/.auto-loop-state"

# Loop settings (all overridable via env vars)
ENGINE="${ENGINE:-claude}"
ENGINE="$(echo "$ENGINE" | tr '[:upper:]' '[:lower:]')"
MODEL="${MODEL:-}"
MODEL_LABEL="${MODEL:-config-default}"
CLAUDE_BIN="${CLAUDE_BIN:-}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
CODEX_BIN="${CODEX_BIN:-}"
CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE:-danger-full-access}"
LOOP_INTERVAL="${LOOP_INTERVAL:-30}"
CYCLE_TIMEOUT_SECONDS="${CYCLE_TIMEOUT_SECONDS:-1800}"
MAX_CONSECUTIVE_ERRORS="${MAX_CONSECUTIVE_ERRORS:-5}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-300}"
LIMIT_WAIT_SECONDS="${LIMIT_WAIT_SECONDS:-3600}"
MAX_LOGS="${MAX_LOGS:-200}"
AUTO_LOOP_PROTECT_GITIGNORE="${AUTO_LOOP_PROTECT_GITIGNORE:-1}"
AUTO_LOOP_PROTECT_MISSION="${AUTO_LOOP_PROTECT_MISSION:-1}"
# Termination. MAX_CYCLES and MAX_RUNTIME_SECONDS are the backstops that make an
# unattended run bounded; without them a model that never declares COMPLETE drains the
# subscription quota indefinitely. Set either to 0 to disable.
MAX_CYCLES="${MAX_CYCLES:-40}"
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-28800}"
STOP_AFTER_CRITERIA="${STOP_AFTER_CRITERIA:-0}"
REQUIRED_COMPLETE_STREAK="${REQUIRED_COMPLETE_STREAK:-2}"
STOP_ON_BLOCKED="${STOP_ON_BLOCKED:-2}"
MAX_LIMIT_WAITS="${MAX_LIMIT_WAITS:-6}"
RESOLVED_ENGINE_BIN=""
complete_streak=0
blocked_streak=0
limit_waits=0
START_EPOCH="$(date +%s)"
# Pre-declared because `set -u` is active and the prompt builder reads them.
MISSION_PRODUCT=""
MISSION_SLUG=""
protected_snapshot=""
STOP_REASON=""
ENGINE_PID=""

if [ "$ENGINE" != "claude" ] && [ "$ENGINE" != "codex" ]; then
    echo "Error: ENGINE must be 'claude' or 'codex' (received: '$ENGINE')."
    exit 1
fi

# Keep Agent Teams compatibility for legacy prompts/config.
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

# Go toolchain, scoped to this loop only (the user's global `go env` is untouched).
#
# Caches are routed into the project because both defaults (~/go/pkg/mod and
# ~/Library/Caches/go-build) sit outside it, and the sandbox only grants write
# inside the project — `go build` would otherwise fail on the cache write.
#
# GOPROXY=off is deliberate and is inherited by the sandboxed agent. Measured
# behaviour on Claude Code 2.1.251: curl reaches proxy.golang.org through the
# sandbox proxy fine (HTTP 200), but the Go toolchain fails the same fetch with
# `tls: failed to verify certificate: x509: OSStatus -26276`, because it does not
# get through the proxy's authenticated CONNECT the way curl and git do. Rather
# than punching a hole in the sandbox for Go, the supervisor — which is a plain
# bash script and is NOT sandboxed — warms the module cache between cycles (see
# warm_go_module_cache). The agent then builds strictly offline.
#
# This is stricter than the original design: the agent can no longer fetch Go
# modules at all; only the supervisor can, and only what is already in go.mod.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="off"
export GOSUMDB="sum.golang.org"
export GOMODCACHE="$PROJECT_DIR/.gocache/mod"
export GOCACHE="$PROJECT_DIR/.gocache/build"

# Proxy used only by the supervisor's own cache warming, never exported to the agent.
GO_FETCH_PROXY="${GO_FETCH_PROXY:-https://proxy.golang.org,direct}"

# === Functions ===

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[$timestamp] $1"
    echo "$msg" >> "$LOG_DIR/auto-loop.log"
    if [ -t 1 ]; then
        echo "$msg"
    fi
}

log_cycle() {
    local cycle_num=$1
    local status=$2
    local msg=$3
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] Cycle #$cycle_num [$status] $msg" >> "$LOG_DIR/auto-loop.log"
    if [ -t 1 ]; then
        echo "[$timestamp] Cycle #$cycle_num [$status] $msg"
    fi
}

check_usage_limit() {
    local output="$1"
    if echo "$output" | grep -qi "usage limit\|rate limit\|too many requests\|resource_exhausted\|overloaded\|quota\|429\|billing\|insufficient credits"; then
        return 0
    fi
    return 1
}

check_stop_requested() {
    if [ -f "$PROJECT_DIR/.auto-loop-stop" ]; then
        rm -f "$PROJECT_DIR/.auto-loop-stop"
        return 0
    fi
    return 1
}

save_state() {
    # The dashboard parses this as KEY=VALUE and ignores keys it does not know, so extra
    # keys are safe. MISSION_PRODUCT is here so `make status` answers the question that
    # actually matters at a glance: is it still building my product?
    cat > "$STATE_FILE" << EOF
LOOP_COUNT=$loop_count
ERROR_COUNT=$error_count
LAST_RUN=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=$1
MODEL=$MODEL_LABEL
ENGINE=$ENGINE
MISSION_PRODUCT=$MISSION_PRODUCT
COMPLETION_STATUS=$(read_completion_status)
CRITERIA=$(criteria_checked)/$(criteria_total)
STOP_REASON=${STOP_REASON:-}
START_EPOCH=$START_EPOCH
EOF
}

kill_engine_child() {
    # `make stop` SIGTERMs the supervisor. Without this the headless engine keeps running
    # and keeps writing files after the user believes the loop has stopped.
    [ -n "${ENGINE_PID:-}" ] || return 0
    if kill -0 "$ENGINE_PID" 2>/dev/null; then
        log "Stopping in-flight engine process $ENGINE_PID"
        pkill -P "$ENGINE_PID" 2>/dev/null || true
        kill -TERM "$ENGINE_PID" 2>/dev/null || true
        sleep 2
        pkill -9 -P "$ENGINE_PID" 2>/dev/null || true
        kill -KILL "$ENGINE_PID" 2>/dev/null || true
    fi
    ENGINE_PID=""
}

cleanup() {
    log "=== Auto Loop Shutting Down (PID $$) ==="
    kill_engine_child
    # First, before anything records state: a stop that lands mid-cycle must not leave
    # a mutated MISSION.md on disk. Otherwise the next start would read the model's
    # rewrite as the mission, and the lock would break at exactly the moment the
    # founder intervened.
    restore_protected_files_if_changed "${protected_snapshot:-}"
    rm -f "$PID_FILE"
    save_state "stopped"
    exit 0
}

snapshot_gitignore() {
    if [ "$AUTO_LOOP_PROTECT_GITIGNORE" = "0" ]; then
        echo ""
        return
    fi

    local gitignore_file="$PROJECT_DIR/.gitignore"
    local snapshot_file=""
    if [ -f "$gitignore_file" ]; then
        snapshot_file=$(mktemp)
        cp "$gitignore_file" "$snapshot_file"
    fi
    echo "$snapshot_file"
}

restore_gitignore_if_changed() {
    local snapshot_file="$1"
    if [ "$AUTO_LOOP_PROTECT_GITIGNORE" = "0" ]; then
        [ -n "$snapshot_file" ] && rm -f "$snapshot_file"
        return
    fi

    local gitignore_file="$PROJECT_DIR/.gitignore"
    local changed=0

    if [ -f "$gitignore_file" ]; then
        if [ -z "$snapshot_file" ] || [ ! -f "$snapshot_file" ]; then
            changed=1
        elif ! cmp -s "$gitignore_file" "$snapshot_file"; then
            changed=1
        fi
    else
        if [ -n "$snapshot_file" ] && [ -f "$snapshot_file" ]; then
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        if [ -n "$snapshot_file" ] && [ -f "$snapshot_file" ]; then
            cp "$snapshot_file" "$gitignore_file"
            log_cycle "$loop_count" "GUARD" "Blocked cycle mutation of .gitignore and restored baseline"
        else
            rm -f "$gitignore_file"
            log_cycle "$loop_count" "GUARD" "Blocked cycle-created .gitignore and removed it"
        fi
    fi

    [ -n "$snapshot_file" ] && rm -f "$snapshot_file"
}

# Founder-owned files. A cycle must never change these; loop-settings.json denies the
# edit up front, and this reverts anything that slips past (a shell redirect, a script
# the agent generated, a tool the deny rules do not cover).
PROTECTED_FILES="MISSION.md CLAUDE.md .gitignore loop-settings.json"

snapshot_protected_files() {
    [ "$AUTO_LOOP_PROTECT_MISSION" = "1" ] || return 0
    local dir rel
    dir="$(mktemp -d "${TMPDIR:-/tmp}/auto-loop-protect.XXXXXX")" || return 0
    for rel in $PROTECTED_FILES; do
        [ -f "$PROJECT_DIR/$rel" ] && cp "$PROJECT_DIR/$rel" "$dir/$(echo "$rel" | tr '/' '_')" 2>/dev/null || true
    done
    echo "$dir"
}

restore_protected_files_if_changed() {
    local dir="${1:-}"
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    local rel snap
    for rel in $PROTECTED_FILES; do
        snap="$dir/$(echo "$rel" | tr '/' '_')"
        [ -f "$snap" ] || continue
        if ! cmp -s "$snap" "$PROJECT_DIR/$rel" 2>/dev/null; then
            cp "$snap" "$PROJECT_DIR/$rel" 2>/dev/null || true
            log_cycle "${loop_count:-0}" "GUARD" "Reverted cycle modification of $rel"
        fi
    done
    rm -rf "$dir" 2>/dev/null || true
}

warm_go_module_cache() {
    # Runs in the supervisor, which is NOT sandboxed, so it can reach the module
    # proxy that the sandboxed agent cannot. Downloads only what the agent already
    # declared in go.mod; it never resolves anything the agent did not write down.
    # A cycle that adds a dependency fails to build, this warms the cache, and the
    # next cycle builds — self-healing with a one-cycle lag.
    command -v go >/dev/null 2>&1 || return 0
    [ -d "$PROJECT_DIR/projects" ] || return 0

    local mod_file module_dir warmed=0
    while IFS= read -r mod_file; do
        module_dir="$(dirname "$mod_file")"
        # `go mod tidy` first so an agent only has to write the import statement:
        # it resolves imports from source into go.mod/go.sum. `download all` then
        # fills the cache so the next sandboxed cycle builds offline.
        if (cd "$module_dir" \
                && GOPROXY="$GO_FETCH_PROXY" GOFLAGS="-mod=mod" go mod tidy >/dev/null 2>&1 \
                && GOPROXY="$GO_FETCH_PROXY" GOFLAGS="-mod=mod" go mod download all >/dev/null 2>&1); then
            warmed=$((warmed + 1))
        else
            log_cycle "$loop_count" "GOWARM" "go mod download failed in ${module_dir#$PROJECT_DIR/}"
        fi
    done < <(find "$PROJECT_DIR/projects" -maxdepth 3 -name go.mod -not -path '*/.gocache/*' 2>/dev/null)

    [ "$warmed" -gt 0 ] && log_cycle "$loop_count" "GOWARM" "Warmed Go module cache for $warmed module(s)"
    return 0
}

get_file_size_bytes() {
    local target_file="$1"
    if [ ! -f "$target_file" ]; then
        echo 0
        return
    fi

    if stat -c%s "$target_file" >/dev/null 2>&1; then
        stat -c%s "$target_file"
        return
    fi

    if stat -f%z "$target_file" >/dev/null 2>&1; then
        stat -f%z "$target_file"
        return
    fi

    wc -c < "$target_file" | tr -d ' '
}

rotate_logs() {
    # Keep only the latest N cycle logs
    local count
    count=$(find "$LOG_DIR" -name "cycle-*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt "$MAX_LOGS" ]; then
        local to_delete=$((count - MAX_LOGS))
        find "$LOG_DIR" -name "cycle-*.log" -type f | sort | head -n "$to_delete" | xargs rm -f 2>/dev/null || true
        log "Log rotation: removed $to_delete old cycle logs"
    fi

    # Rotate main log if over 10MB
    local log_size
    log_size=$(get_file_size_bytes "$LOG_DIR/auto-loop.log")
    if [ "$log_size" -gt 10485760 ]; then
        mv "$LOG_DIR/auto-loop.log" "$LOG_DIR/auto-loop.log.old"
        log "Main log rotated (was ${log_size} bytes)"
    fi
}

cleanup_accidental_root_artifacts() {
    local removed=0
    local removed_names=""
    local f base

    # Known accidental artifacts caused by malformed shell redirections in generated commands.
    for f in "$PROJECT_DIR"/=* "$PROJECT_DIR"/口径说明*; do
        [ -f "$f" ] || continue
        if [ ! -s "$f" ]; then
            rm -f "$f"
            removed=$((removed + 1))
            base=$(basename "$f")
            if [ -z "$removed_names" ]; then
                removed_names="$base"
            else
                removed_names="$removed_names, $base"
            fi
        fi
    done

    if [ "$removed" -gt 0 ]; then
        log_cycle "$loop_count" "GUARD" "Removed accidental root zero-byte artifact(s): $removed_names"
    fi
}

backup_consensus() {
    if [ -f "$CONSENSUS_FILE" ]; then
        cp "$CONSENSUS_FILE" "$CONSENSUS_FILE.bak"
    fi
}

seed_consensus() {
    # Generate a contract-valid baseline from MISSION.md. Called whenever the consensus
    # does not satisfy validate_consensus, at startup and as the last resort on restore.
    mkdir -p "$(dirname "$CONSENSUS_FILE")"
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
        echo "- (seed) Loop initialised under mission lock."
        echo
        echo "## Key Decisions Made"
        echo "- Product is fixed by MISSION.md. No idea selection in this run."
        echo
        echo "## Active Projects"
        echo "- $MISSION_PRODUCT: not started - scaffold under projects/$MISSION_SLUG"
        echo
        echo "## Acceptance Criteria"
        sed -n '/^## Definition of Done/,$p' "$MISSION_FILE" \
            | grep -E '^- \[[ xX]\]' \
            | sed 's/^- \[[xX]\]/- [ ]/' \
            || echo "- [ ] (copy from MISSION.md Definition of Done)"
        echo
        echo "## Completion Status"
        echo "IN_PROGRESS"
        echo
        echo "## Completion Evidence"
        echo "(none yet)"
        echo
        echo "## Next Action"
        echo "Scaffold projects/$MISSION_SLUG and deliver the first unchecked acceptance criterion."
        echo
        echo "## Company State"
        echo "- Product: $MISSION_PRODUCT"
        echo "- Tech Stack: Go"
        echo "- Revenue: \$0"
        echo "- Users: 0"
        echo
        echo "## Open Questions"
        echo "- (none yet)"
    } > "$CONSENSUS_FILE"
}

restore_consensus() {
    # Never restore a backup that is itself invalid. Doing so creates a loop that looks
    # like work but produces nothing: the file fails validation at both ends of every
    # cycle, each cycle is marked FAIL, the breaker sleeps and resets, and the run burns
    # quota forever. Re-seed instead.
    if [ -f "$CONSENSUS_FILE.bak" ]; then
        cp "$CONSENSUS_FILE.bak" "$CONSENSUS_FILE"
        if validate_consensus; then
            log "Consensus restored from backup after failed cycle"
            return 0
        fi
        log "Backup consensus is also invalid - re-seeding from MISSION.md"
    else
        log "No consensus backup - seeding from MISSION.md"
    fi
    seed_consensus
}

validate_consensus() {
    if [ ! -s "$CONSENSUS_FILE" ]; then
        return 1
    fi
    if ! grep -q "^# Auto Company Consensus" "$CONSENSUS_FILE"; then
        return 1
    fi
    if ! grep -q "^## Next Action" "$CONSENSUS_FILE"; then
        return 1
    fi
    if ! grep -q "^## Company State" "$CONSENSUS_FILE"; then
        return 1
    fi
    # Added by the mission lock: completion detection reads both of these, and a cycle
    # that drops them would leave the run with no way to ever finish.
    if ! grep -q "^## Acceptance Criteria" "$CONSENSUS_FILE"; then
        return 1
    fi
    if ! grep -q "^## Completion Status" "$CONSENSUS_FILE"; then
        return 1
    fi
    return 0
}

read_completion_status() {
    sed -n '/^## Completion Status/,/^## /p' "$CONSENSUS_FILE" 2>/dev/null \
        | grep -Ev '^## ' | grep -Eo 'IN_PROGRESS|BLOCKED|COMPLETE' | head -1
}

criteria_total() {
    sed -n '/^## Acceptance Criteria/,/^## /p' "$CONSENSUS_FILE" 2>/dev/null | grep -cE '^- \[[ xX]\]'
}

criteria_checked() {
    sed -n '/^## Acceptance Criteria/,/^## /p' "$CONSENSUS_FILE" 2>/dev/null | grep -cE '^- \[[xX]\]'
}

completion_evidence_present() {
    # Require the model to paste something that looks like real command output. This is a
    # weak check by nature - it raises the cost of lying, it does not make lying impossible.
    local body
    body=$(sed -n '/^## Completion Evidence/,/^## /p' "$CONSENSUS_FILE" 2>/dev/null | grep -Ev '^## ')
    printf '%s' "$body" | grep -qE 'go (build|test|vet)'
}

completion_accepted() {
    # COMPLETE counts only when every criterion is ticked, there is at least one criterion,
    # and evidence is present. The caller additionally requires the condition to survive
    # REQUIRED_COMPLETE_STREAK consecutive cycles, each a fresh session.
    local total checked
    total=$(criteria_total)
    checked=$(criteria_checked)
    [ "$total" -gt 0 ] || return 1
    [ "$checked" -eq "$total" ] || return 1
    completion_evidence_present || return 1
    return 0
}

freeze_state() {
    local reason="$1"
    local stamp freeze_dir
    stamp="$(date '+%Y%m%d-%H%M%S')"
    freeze_dir="$PROJECT_DIR/memories/freeze/${stamp}-${reason}"
    mkdir -p "$freeze_dir" 2>/dev/null || return 0
    cp "$CONSENSUS_FILE" "$freeze_dir/consensus.md" 2>/dev/null || true
    cp "$STATE_FILE" "$freeze_dir/auto-loop-state" 2>/dev/null || true
    cp "$MISSION_FILE" "$freeze_dir/MISSION.md" 2>/dev/null || true
    ls -1t "$LOG_DIR"/cycle-*.log 2>/dev/null | head -1 | while read -r last_log; do
        cp "$last_log" "$freeze_dir/last-cycle.log" 2>/dev/null || true
    done
    {
        echo "# Run Freeze"
        echo
        echo "- Reason: $reason"
        echo "- Product: $MISSION_PRODUCT"
        echo "- Cycles completed: ${loop_count:-0}"
        echo "- Runtime: $(( $(date +%s) - START_EPOCH ))s"
        echo "- Criteria: $(criteria_checked)/$(criteria_total) checked"
        echo "- Completion status: $(read_completion_status)"
        echo
        echo "Resume with: rm -f .auto-loop-paused && make start"
        if [ "$reason" = "completed" ]; then
            echo "This run finished. Starting again requires RESET_RUN=1."
        fi
    } > "$freeze_dir/SUMMARY.md" 2>/dev/null || true
    echo "$freeze_dir"
}

terminal_stop() {
    local reason="$1" detail="$2"
    log_cycle "${loop_count:-0}" "STOP" "$detail"
    kill_engine_child
    restore_protected_files_if_changed "${protected_snapshot:-}"
    local freeze_dir
    freeze_dir="$(freeze_state "$reason")"
    [ -n "$freeze_dir" ] && log "Frozen state written to ${freeze_dir#$PROJECT_DIR/}"
    # Without this flag launchd's KeepAlive respawns the loop within 30s and the "stop"
    # is fiction. stop-loop.sh --pause-daemon relies on the same marker.
    touch "$PROJECT_DIR/.auto-loop-paused"
    STOP_REASON="$reason"
    save_state "$reason"
    log "=== Auto Loop Finished: $reason ==="
    rm -f "$PID_FILE"
    exit 0
}

consensus_changed_since_backup() {
    if [ ! -f "$CONSENSUS_FILE" ]; then
        return 1
    fi

    if [ ! -f "$CONSENSUS_FILE.bak" ]; then
        return 0
    fi

    if cmp -s "$CONSENSUS_FILE" "$CONSENSUS_FILE.bak"; then
        return 1
    fi

    return 0
}

resolve_codex_bin() {
    if [ -n "$CODEX_BIN" ]; then
        if [ -x "$CODEX_BIN" ]; then
            echo "$CODEX_BIN"
            return 0
        fi
        if command -v "$CODEX_BIN" >/dev/null 2>&1; then
            command -v "$CODEX_BIN"
            return 0
        fi
    fi

    # Prefer WSL-local Codex installed via nvm.
    local nvm_candidate=""
    for candidate in "$HOME"/.nvm/versions/node/*/bin/codex; do
        if [ -x "$candidate" ]; then
            nvm_candidate="$candidate"
        fi
    done
    if [ -n "$nvm_candidate" ]; then
        echo "$nvm_candidate"
        return 0
    fi

    # Fallback: ask an interactive bash shell (loads user profile).
    local interactive_candidate
    interactive_candidate=$(bash -ic 'command -v codex' 2>/dev/null | tail -n1 | tr -d '\r' || true)
    if [ -n "$interactive_candidate" ] && [ -x "$interactive_candidate" ]; then
        echo "$interactive_candidate"
        return 0
    fi

    # Last fallback: current shell PATH.
    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    return 1
}

resolve_claude_bin() {
    if [ -n "$CLAUDE_BIN" ]; then
        if [ -x "$CLAUDE_BIN" ]; then
            echo "$CLAUDE_BIN"
            return 0
        fi
        if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
            command -v "$CLAUDE_BIN"
            return 0
        fi
    fi

    # Prefer WSL-local Claude CLI installed via nvm.
    local nvm_candidate=""
    for candidate in "$HOME"/.nvm/versions/node/*/bin/claude; do
        if [ -x "$candidate" ]; then
            nvm_candidate="$candidate"
        fi
    done
    if [ -n "$nvm_candidate" ]; then
        echo "$nvm_candidate"
        return 0
    fi

    # Fallback: ask an interactive bash shell (loads user profile).
    local interactive_candidate
    interactive_candidate=$(bash -ic 'command -v claude' 2>/dev/null | tail -n1 | tr -d '\r' || true)
    if [ -n "$interactive_candidate" ] && [ -x "$interactive_candidate" ]; then
        echo "$interactive_candidate"
        return 0
    fi

    # Last fallback: current shell PATH.
    if command -v claude >/dev/null 2>&1; then
        command -v claude
        return 0
    fi

    return 1
}

resolve_engine_bin() {
    case "$ENGINE" in
        claude)
            resolve_claude_bin
            ;;
        codex)
            resolve_codex_bin
            ;;
        *)
            return 1
            ;;
    esac
}

run_codex_cycle() {
    local prompt="$1"
    local output_file timeout_flag message_file

    output_file=$(mktemp)
    timeout_flag=$(mktemp)
    message_file=$(mktemp)

    set +e
    (
        cd "$PROJECT_DIR" || exit 1
        local codex_cmd=("$RESOLVED_ENGINE_BIN" "exec" "-c" "sandbox_mode=\"${CODEX_SANDBOX_MODE}\"" "-o" "$message_file")
        if [ -n "$MODEL" ]; then
            codex_cmd+=("-m" "$MODEL")
        fi
        codex_cmd+=("$prompt")
        "${codex_cmd[@]}"
    ) > "$output_file" 2>&1 &
    local codex_pid=$!

    (
        sleep "$CYCLE_TIMEOUT_SECONDS"
        if kill -0 "$codex_pid" 2>/dev/null; then
            echo "1" > "$timeout_flag"
            kill -TERM "$codex_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$codex_pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!

    wait "$codex_pid"
    EXIT_CODE=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    set -e

    OUTPUT=$(cat "$output_file")
    RESULT_MESSAGE=$(cat "$message_file" 2>/dev/null || true)
    rm -f "$output_file" "$message_file"

    if [ -s "$timeout_flag" ]; then
        CYCLE_TIMED_OUT=1
        EXIT_CODE=124
    else
        CYCLE_TIMED_OUT=0
    fi
    rm -f "$timeout_flag"
}

run_claude_cycle() {
    local prompt="$1"
    local output_file timeout_flag

    output_file=$(mktemp)
    timeout_flag=$(mktemp)

    set +e
    (
        cd "$PROJECT_DIR" || exit 1
        local claude_cmd=("$RESOLVED_ENGINE_BIN" "-p" "$prompt" "--output-format" "json")
        # Sandbox, deny rules and the Bash guard hook live here rather than in
        # .claude/settings.json so they bind the unattended loop without also
        # binding interactive sessions in this repo.
        claude_cmd+=("--settings" "$LOOP_SETTINGS_FILE")
        if [ -n "$MODEL" ]; then
            claude_cmd+=("--model" "$MODEL")
        fi
        if [ -n "$CLAUDE_PERMISSION_MODE" ]; then
            claude_cmd+=("--permission-mode" "$CLAUDE_PERMISSION_MODE")
        fi
        "${claude_cmd[@]}"
    ) > "$output_file" 2>&1 &
    local claude_pid=$!
    ENGINE_PID="$claude_pid"

    (
        sleep "$CYCLE_TIMEOUT_SECONDS"
        if kill -0 "$claude_pid" 2>/dev/null; then
            echo "1" > "$timeout_flag"
            kill -TERM "$claude_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$claude_pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!

    wait "$claude_pid"
    EXIT_CODE=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    set -e

    OUTPUT=$(cat "$output_file")
    RESULT_MESSAGE="$OUTPUT"
    rm -f "$output_file"

    if [ -s "$timeout_flag" ]; then
        CYCLE_TIMED_OUT=1
        EXIT_CODE=124
    else
        CYCLE_TIMED_OUT=0
    fi
    rm -f "$timeout_flag"
}

run_engine_cycle() {
    local prompt="$1"
    case "$ENGINE" in
        claude)
            run_claude_cycle "$prompt"
            ;;
        codex)
            run_codex_cycle "$prompt"
            ;;
        *)
            echo "Error: Unsupported ENGINE '$ENGINE'" >&2
            return 1
            ;;
    esac
}

extract_cycle_metadata() {
    RESULT_TEXT=""
    CYCLE_COST="N/A"
    CYCLE_SUBTYPE="unknown"
    CYCLE_TYPE="${ENGINE}_exec"

    if [ "$ENGINE" = "claude" ]; then
        if command -v jq >/dev/null 2>&1; then
            RESULT_TEXT=$(echo "$RESULT_MESSAGE" | jq -r '.result // .message // .output_text // empty' 2>/dev/null | head -c 2000 || true)
            if [ -z "$RESULT_TEXT" ]; then
                RESULT_TEXT=$(echo "$RESULT_MESSAGE" | jq -r '.. | .text? // empty' 2>/dev/null | head -c 2000 || true)
            fi

            parsed_cost=$(echo "$RESULT_MESSAGE" | jq -r '.total_cost_usd // .cost_usd // empty' 2>/dev/null || true)
            if [ -n "$parsed_cost" ]; then
                CYCLE_COST="$parsed_cost"
            fi

            parsed_subtype=$(echo "$RESULT_MESSAGE" | jq -r '.subtype // empty' 2>/dev/null || true)
            if [ -n "$parsed_subtype" ]; then
                CYCLE_SUBTYPE="$parsed_subtype"
            fi

            parsed_type=$(echo "$RESULT_MESSAGE" | jq -r '.type // empty' 2>/dev/null || true)
            if [ -n "$parsed_type" ]; then
                CYCLE_TYPE="$parsed_type"
            fi
        fi

        if [ -z "$RESULT_TEXT" ]; then
            RESULT_TEXT=$(echo "$OUTPUT" | head -c 2000 || true)
        fi

        if [ "$CYCLE_SUBTYPE" = "unknown" ]; then
            if [ "$EXIT_CODE" -eq 0 ]; then
                CYCLE_SUBTYPE="success"
            else
                CYCLE_SUBTYPE="error"
            fi
        fi
        return
    fi

    RESULT_TEXT=$(echo "$RESULT_MESSAGE" | head -c 2000 || true)
    if [ -z "$RESULT_TEXT" ]; then
        RESULT_TEXT=$(echo "$OUTPUT" | head -c 2000 || true)
    fi

    if [ "$EXIT_CODE" -eq 0 ]; then
        CYCLE_SUBTYPE="success"
    else
        CYCLE_SUBTYPE="error"
    fi
}

# === Setup ===

mkdir -p "$LOG_DIR" "$PROJECT_DIR/memories"

# Clean up stale stop file from previous run
rm -f "$PROJECT_DIR/.auto-loop-stop"

# Check for existing instance
if [ -f "$PID_FILE" ]; then
    existing_pid=$(cat "$PID_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "Auto loop already running (PID $existing_pid). Stop it first with ./stop-loop.sh"
        exit 1
    fi
fi

# Check dependencies
if ! RESOLVED_ENGINE_BIN="$(resolve_engine_bin)"; then
    if [ "$ENGINE" = "claude" ]; then
        echo "Error: Claude CLI not found. Install Claude Code in WSL and verify with 'claude --version'."
    else
        echo "Error: Codex CLI not found. Install Codex in WSL and verify with 'codex --version'."
    fi
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: PROMPT.md not found at $PROMPT_FILE"
    exit 1
fi

# Mission lock. Fail fast rather than falling back to legacy behaviour: a missing or
# unfilled brief must never silently resume "pick your own product" mode.
if [ ! -f "$MISSION_FILE" ]; then
    echo "Error: MISSION.md not found at $MISSION_FILE"
    echo "This loop is mission-locked and will not choose a product for itself."
    exit 1
fi

MISSION_PRODUCT="$(grep -m1 '^\*\*Product:\*\*' "$MISSION_FILE" | sed 's/^\*\*Product:\*\* *//' | tr -d '\r' || true)"
if [ -z "$MISSION_PRODUCT" ] || [ "$MISSION_PRODUCT" = "TBD" ]; then
    echo "Error: MISSION.md has no product yet."
    echo "Set a real name on the '**Product:** ...' line and fill in Definition of Done."
    exit 1
fi

if ! grep -q '^## Definition of Done' "$MISSION_FILE"; then
    echo "Error: MISSION.md is missing the '## Definition of Done' section."
    echo "Without it the loop has no completion criteria and could never finish."
    exit 1
fi

MISSION_SLUG="$(echo "$MISSION_PRODUCT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')"

check_single_product() {
    # Warn if a directory appears under projects/ that is neither the mission's own nor
    # the known leftover. Cheap early signal that the team started a second product.
    [ -d "$PROJECT_DIR/projects" ] || return 0
    local entry name
    for entry in "$PROJECT_DIR/projects"/*/; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        case "$name" in
            "$MISSION_SLUG"|snapog) ;;
            *) log_cycle "${loop_count:-0}" "GUARD" "Unexpected project directory 'projects/$name' - mission is '$MISSION_SLUG'" ;;
        esac
    done
    return 0
}

# Refuse to run unguarded. These two files are the entire enforcement layer;
# if either is missing the loop would still work, which is exactly the failure
# we must never have — an autonomous run that silently lost its sandbox.
if [ "$ENGINE" = "claude" ] && [ ! -f "$LOOP_SETTINGS_FILE" ]; then
    echo "Error: loop-settings.json not found at $LOOP_SETTINGS_FILE"
    echo "It carries the sandbox, deny rules and Bash guard hook. Refusing to run unguarded."
    exit 1
fi

if [ ! -x "$PROJECT_DIR/scripts/core/guard-bash.sh" ]; then
    echo "Error: scripts/core/guard-bash.sh is missing or not executable."
    echo "The PreToolUse guard would silently not run. Fix with: chmod +x scripts/core/guard-bash.sh"
    exit 1
fi

# A completed run must not silently restart: the consensus still says COMPLETE with every
# box ticked, so the loop would accept it, "confirm" it and stop again having built nothing.
if [ -f "$STATE_FILE" ] && grep -q '^STOP_REASON=completed' "$STATE_FILE" 2>/dev/null; then
    if [ "${RESET_RUN:-0}" != "1" ]; then
        echo "This run already finished (STOP_REASON=completed)."
        echo "Inspect memories/freeze/ first. To start a fresh run: RESET_RUN=1 make start"
        exit 1
    fi
    echo "RESET_RUN=1: clearing consensus and starting a fresh run."
    rm -f "$CONSENSUS_FILE" "$CONSENSUS_FILE.bak"
fi

# Seed or repair the consensus so cycle 1 starts from a contract-valid baseline. Without
# this, a consensus that fails the tightened validation is copied to .bak and restored
# from .bak every cycle, and the run fails forever while looking busy.
if ! validate_consensus; then
    seed_consensus
    echo "Seeded memories/consensus.md from MISSION.md"
fi

if [ -f "$PROJECT_DIR/.auto-loop-paused" ]; then
    echo "Note: .auto-loop-paused exists; removing it so this foreground run proceeds."
    rm -f "$PROJECT_DIR/.auto-loop-paused"
fi

# Write PID file
echo $$ > "$PID_FILE"

# Trap signals for graceful shutdown
trap cleanup SIGTERM SIGINT SIGHUP

# Initialize counters
loop_count=0
error_count=0

log "=== Auto Company Loop Started (PID $$) ==="
log "Project: $PROJECT_DIR"
if [ "$ENGINE" = "codex" ]; then
    log "Engine: codex | Model: $MODEL_LABEL | Sandbox: $CODEX_SANDBOX_MODE"
else
    log "Engine: claude | Model: $MODEL_LABEL | PermissionMode: $CLAUDE_PERMISSION_MODE"
fi
log "Engine bin: $RESOLVED_ENGINE_BIN"
engine_version=$("$RESOLVED_ENGINE_BIN" --version 2>/dev/null | head -n1 || true)
case "$RESOLVED_ENGINE_BIN" in
    /mnt/c/*)
        if [ "$ENGINE" = "codex" ]; then
            log "Warning: Codex binary resolves to Windows-mounted path. Prefer WSL-local install for stability."
        else
            log "Warning: Claude binary resolves to Windows-mounted path. Prefer WSL-local install for stability."
        fi
        ;;
esac
if [ -n "$engine_version" ]; then
    if [ "$ENGINE" = "codex" ]; then
        log "Codex version: $engine_version"
    else
        log "Claude version: $engine_version"
    fi
fi
log "Interval: ${LOOP_INTERVAL}s | Timeout: ${CYCLE_TIMEOUT_SECONDS}s | Breaker: ${MAX_CONSECUTIVE_ERRORS} errors"

# === Main Loop ===

while true; do
    # Check for stop request
    if check_stop_requested; then
        log "Stop requested. Shutting down gracefully."
        cleanup
    fi

    # Backstops, checked before starting work so a run can overshoot by at most the
    # cycle already in flight. Set the caps slightly below the true ceiling.
    if [ "$MAX_CYCLES" -gt 0 ] && [ "$loop_count" -ge "$MAX_CYCLES" ]; then
        terminal_stop "stopped_cap" "Reached MAX_CYCLES=$MAX_CYCLES"
    fi
    if [ "$MAX_RUNTIME_SECONDS" -gt 0 ]; then
        elapsed=$(( $(date +%s) - START_EPOCH ))
        if [ "$elapsed" -ge "$MAX_RUNTIME_SECONDS" ]; then
            terminal_stop "stopped_cap" "Reached MAX_RUNTIME_SECONDS=$MAX_RUNTIME_SECONDS (ran ${elapsed}s)"
        fi
    fi

    loop_count=$((loop_count + 1))
    cycle_log="$LOG_DIR/cycle-$(printf '%04d' "$loop_count")-$(date '+%Y%m%d-%H%M%S').log"

    log_cycle "$loop_count" "START" "Beginning work cycle"
    save_state "running"

    # Log rotation
    rotate_logs

    # Backup consensus before cycle
    backup_consensus
    gitignore_snapshot=$(snapshot_gitignore)
    protected_snapshot=$(snapshot_protected_files)

    # Build prompt: mission lock first, then guardrails, then the legacy cycle prompt.
    # Order matters. Bash does not re-scan the result of a parameter expansion, so a
    # MISSION.md containing $, backticks or backslashes is inserted literally and safely.
    PROMPT=$(cat "$PROMPT_FILE")
    MISSION=$(cat "$MISSION_FILE")
    CONSENSUS=$(cat "$CONSENSUS_FILE" 2>/dev/null || echo "No consensus file found. This is the very first cycle.")
    FULL_PROMPT="## MISSION LOCK — highest priority, overrides everything below

You are building exactly one product: **$MISSION_PRODUCT**. It is already chosen. Do not
brainstorm alternatives, do not evaluate other ideas, do not pivot, and do not start a
second product. If a rule further down this prompt tells you to generate ideas, rank
options, run a GO/NO-GO, or change direction, that rule is superseded — ignore it and
advance this mission instead. If you are stuck, narrow the current task; never change
the product.

The full brief follows. It is read-only: any edit you make to MISSION.md is reverted.

$MISSION

---

## Hard Safety Rules (enforced outside this prompt as well)

- Never run \`gh\`, \`wrangler\`, \`git push\`, \`git remote\`, \`git reset\`, \`sudo\`, or \`launchctl\`.
  This run is local-only; those are blocked and attempts are logged.
- Never read or write \`~/.ssh\`, \`~/.aws\`, \`~/.claude\`, or any \`.env\` file.
- Never edit MISSION.md, CLAUDE.md, .gitignore, loop-settings.json, or anything under
  .claude/, .github/, scripts/, dashboard/, or tests/. Those are founder-owned.
- Build the product only under \`projects/\`. Never create files outside this repository.
- \`go get\` does not work here by design (\`GOPROXY=off\`). To add a dependency, write the
  \`import\` statement and move on; the supervisor resolves it before the next cycle.

---

## Runtime Guardrails (must follow)

1. Early in the cycle, create or update \`memories/consensus.md\` with the required section skeleton.
2. If work scope is large, persist partial decisions to \`memories/consensus.md\` before deep dives.
3. Prefer shipping one completed milestone over broad parallel exploration.
4. Never write files via shell heredoc (\`cat <<EOF\`). Use \`apply_patch\` for file creates/edits.
5. Never execute shell lines that begin with \`>\` or \`>=\`; treat them as text and keep them inside markdown/files.

---

## Current Consensus (pre-loaded, do NOT re-read this file)

$CONSENSUS

---

This is Cycle #$loop_count. Act decisively."

    # Verify the mission actually made it into the prompt. If an edit to the block above
    # ever breaks the expansion, the failure is otherwise silent: the model simply never
    # sees the mission and wanders off, which is the exact outcome this design prevents.
    if ! printf '%s' "$FULL_PROMPT" | grep -Fq "$MISSION_PRODUCT"; then
        log_cycle "$loop_count" "FAIL" "Mission missing from built prompt - refusing to run cycle"
        save_state "stopped"
        cleanup
    fi

    prompt_bytes=$(printf '%s' "$FULL_PROMPT" | wc -c | tr -d ' ')
    if [ "$prompt_bytes" -gt 800000 ]; then
        log_cycle "$loop_count" "WARN" "Prompt is ${prompt_bytes} bytes, approaching ARG_MAX; trim memories/consensus.md"
    fi

    # Run selected engine in headless mode with per-cycle timeout
    run_engine_cycle "$FULL_PROMPT"

    # Save full output to cycle log
    echo "$OUTPUT" > "$cycle_log"

    # Clean up known malformed-redirection artifacts created by bad generated shell commands.
    cleanup_accidental_root_artifacts
    restore_gitignore_if_changed "$gitignore_snapshot"
    restore_protected_files_if_changed "$protected_snapshot"
    protected_snapshot=""
    check_single_product
    warm_go_module_cache

    # Extract result fields for status classification
    extract_cycle_metadata

    cycle_failed_reason=""
    cycle_soft_timeout=0
    if [ "$CYCLE_TIMED_OUT" -eq 1 ]; then
        if validate_consensus && consensus_changed_since_backup; then
            cycle_soft_timeout=1
        else
            cycle_failed_reason="Timed out after ${CYCLE_TIMEOUT_SECONDS}s"
        fi
    elif [ "$EXIT_CODE" -ne 0 ]; then
        cycle_failed_reason="Exit code $EXIT_CODE"
    elif ! validate_consensus; then
        cycle_failed_reason="consensus.md validation failed after cycle"
    fi

    if [ "$cycle_soft_timeout" -eq 1 ]; then
        log_cycle "$loop_count" "OK" "Timed out after ${CYCLE_TIMEOUT_SECONDS}s but consensus was updated; keeping progress (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE})"
        if [ -n "$RESULT_TEXT" ]; then
            log_cycle "$loop_count" "SUMMARY" "$(echo "$RESULT_TEXT" | head -c 300)"
        fi
        error_count=0
    elif [ -z "$cycle_failed_reason" ]; then
        log_cycle "$loop_count" "OK" "Completed (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE})"
        if [ -n "$RESULT_TEXT" ]; then
            log_cycle "$loop_count" "SUMMARY" "$(echo "$RESULT_TEXT" | head -c 300)"
        fi
        error_count=0
    else
        error_count=$((error_count + 1))
        log_cycle "$loop_count" "FAIL" "$cycle_failed_reason (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE}, errors: $error_count/$MAX_CONSECUTIVE_ERRORS)"

        # Restore consensus on hard failure
        restore_consensus

        # Check for usage limit
        if check_usage_limit "$OUTPUT"; then
            limit_waits=$((limit_waits + 1))
            if [ "$MAX_LIMIT_WAITS" -gt 0 ] && [ "$limit_waits" -gt "$MAX_LIMIT_WAITS" ]; then
                terminal_stop "stopped_cap" "Hit the usage limit $limit_waits times - giving up instead of waiting again"
            fi
            log_cycle "$loop_count" "LIMIT" "API usage limit detected. Waiting ${LIMIT_WAIT_SECONDS}s (${limit_waits}/${MAX_LIMIT_WAITS})..."
            save_state "waiting_limit"
            sleep "$LIMIT_WAIT_SECONDS"
            error_count=0
            continue
        fi

        # Circuit breaker
        if [ "$error_count" -ge "$MAX_CONSECUTIVE_ERRORS" ]; then
            log_cycle "$loop_count" "BREAKER" "Circuit breaker tripped! Cooling down ${COOLDOWN_SECONDS}s..."
            save_state "circuit_break"
            sleep "$COOLDOWN_SECONDS"
            error_count=0
            log "Circuit breaker reset. Resuming..."
        fi
    fi

    # Completion detection. Runs only on a cycle that succeeded, so the consensus has
    # already passed validate_consensus and the sections below are known to exist.
    if [ -z "$cycle_failed_reason" ]; then
        cycle_status="$(read_completion_status)"

        if [ "$cycle_status" = "COMPLETE" ] && completion_accepted; then
            complete_streak=$((complete_streak + 1))
            log_cycle "$loop_count" "DONE?" "COMPLETE claimed and criteria verified ($complete_streak/$REQUIRED_COMPLETE_STREAK)"
            if [ "$complete_streak" -ge "$REQUIRED_COMPLETE_STREAK" ]; then
                terminal_stop "completed" "Product complete: $(criteria_checked)/$(criteria_total) criteria, confirmed $complete_streak cycles running"
            fi
        else
            if [ "$cycle_status" = "COMPLETE" ]; then
                # Claimed done without meeting the bar. Say so loudly; the next cycle sees
                # the unchecked boxes and keeps working.
                log_cycle "$loop_count" "REJECT" "COMPLETE rejected: $(criteria_checked)/$(criteria_total) criteria checked, evidence $(completion_evidence_present && echo present || echo missing)"
            fi
            complete_streak=0
        fi

        if [ "$cycle_status" = "BLOCKED" ]; then
            blocked_streak=$((blocked_streak + 1))
            log_cycle "$loop_count" "BLOCKED" "Team reports blocked ($blocked_streak/$STOP_ON_BLOCKED)"
            if [ "$STOP_ON_BLOCKED" -gt 0 ] && [ "$blocked_streak" -ge "$STOP_ON_BLOCKED" ]; then
                terminal_stop "blocked" "Blocked for $blocked_streak consecutive cycles - needs a human"
            fi
        else
            blocked_streak=0
        fi

        if [ "$STOP_AFTER_CRITERIA" -gt 0 ] && [ "$(criteria_checked)" -ge "$STOP_AFTER_CRITERIA" ]; then
            terminal_stop "stopped_cap" "Reached STOP_AFTER_CRITERIA=$STOP_AFTER_CRITERIA ($(criteria_checked) checked)"
        fi
    fi

    save_state "idle"
    log_cycle "$loop_count" "WAIT" "Sleeping ${LOOP_INTERVAL}s before next cycle..."
    sleep "$LOOP_INTERVAL"
done
