#!/bin/bash
# ============================================================
# Auto Company — PreToolUse Bash guard
# ============================================================
# Registered from loop-settings.json, so it runs ONLY for the
# autonomous loop, never for interactive sessions in this repo.
#
# Contract: stdin is the PreToolUse JSON payload. Exit 2 blocks the
# tool call before permission rules are evaluated; exit 0 defers to
# the normal flow.
#
# This is a tripwire and an audit log, NOT a security boundary. It
# cannot see inside a script the command invokes, `node -e`, `npx`,
# or a wrapper it does not know. The Seatbelt sandbox and the deny
# rules in loop-settings.json are the enforcement; this adds a record
# of what was attempted and catches the obvious evasions.
#
# It fails OPEN on purpose: a guard that blocks every command when jq
# is missing would silently halt the loop with no diagnosis.
# ============================================================

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
AUDIT_LOG="$PROJECT_DIR/logs/guard-audit.log"

payload="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0

mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true

log_attempt() {
    printf '%s | %-7s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${cmd//$'\n'/ }" >> "$AUDIT_LOG" 2>/dev/null || true
}

# High-signal patterns, written loosely so extra whitespace and leading
# variable assignments do not slip past. Deliberately short: every entry
# here is one we would rather over-block than miss.
BLOCK_RE='(^|[;&|[:space:]])(sudo|launchctl|crontab)([[:space:]]|$)'
BLOCK_RE="$BLOCK_RE"'|(^|[;&|[:space:]])(gh|wrangler)([[:space:]]|$)'
BLOCK_RE="$BLOCK_RE"'|git[[:space:]]+(push|remote)([[:space:]]|$)'
BLOCK_RE="$BLOCK_RE"'|rm[[:space:]]+(-[[:alnum:]]*[[:space:]]+)*-?[[:alnum:]]*[rf]{2}[[:alnum:]]*[[:space:]]+(/|~|\$HOME)'
BLOCK_RE="$BLOCK_RE"'|(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'
BLOCK_RE="$BLOCK_RE"'|(\.ssh|\.aws|\.gnupg)/'
# Only the HOME copy of .claude is off limits: it holds the user's credentials and config.
# The project's own .claude/ carries the skills and agent definitions the cycle prompt
# explicitly tells the team to read, so blocking it made the loop unable to follow its own
# instructions. Writes there stay blocked by the Edit(/.claude/**) deny rule.
BLOCK_RE="$BLOCK_RE"'|(~|\$HOME|/Users/[^/[:space:]]+)/\.claude'

if printf '%s' "$cmd" | grep -Eq "$BLOCK_RE"; then
    log_attempt "BLOCKED"
    echo "guard-bash: command blocked by Auto Company loop guard: $cmd" >&2
    exit 2
fi

log_attempt "allow"
exit 0
