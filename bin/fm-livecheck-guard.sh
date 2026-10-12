#!/usr/bin/env bash
# fm-livecheck-guard.sh - the live-status Stop hook for a Claude firstmate
# PRIMARY session: a captain-facing reply may not name a work item whose live
# status this turn never looked up. docs/livecheck-guard.md owns the rule;
# bin/fm-livecheck-lib.sh owns the item and lookup formats this hook applies.
#
# Ledgers, status lines, and backlog notes are history, not status; the doc
# above records why that is enforced here rather than remembered.
#
# Registered in tracked .claude/settings.json as a third Stop command hook
# beside bin/fm-turnend-guard.sh --claude and bin/fm-claude-stop-autoarm.sh,
# with the same Grok marker guard and Cursor payload stand-down
# (bin/fm-hook-host-lib.sh). Claude is the only supported harness: the
# decision needs the Stop payload's last_assistant_message (or the turn's
# trailing assistant text from transcript_path) and the turn's tool calls from
# transcript_path, which only Claude's Stop payload carries. The hook refuses
# any flag other than --claude.
#
# Scope: exactly bin/fm-primary-scope-lib.sh - the main home or a validly
# marked secondmate home - so a crewmate or scout worktree working on
# firstmate itself stays inert. A present config/livecheck-off opts a home out.
#
# Decision, in order:
#   1. unreadable or absent payload, missing jq, foreign-host payload, out of
#      scope, or opted out: exit 0 silently.
#   2. no work item in the reply (bin/fm-livecheck-lib.sh
#      fm_livecheck_extract_items): exit 0 and reset the block count.
#   3. every named item was looked up live this turn
#      (fm_livecheck_verified over fm_livecheck_turn_records): exit 0 and reset
#      the block count.
#   4. the transcript cannot be read, so nothing can be judged: exit 0 and
#      print a {"systemMessage"} naming the items left unverified.
#   5. otherwise block: exit 2 with a banner (stderr) that names every
#      unverified item and the one command that checks them all,
#      bin/fm-verify-items.sh, bounded to FM_LIVECHECK_BLOCK_BUDGET (default 2)
#      consecutive blocks per session. The next stop after the budget is spent
#      is allowed with a {"systemMessage"} that names what stayed unverified,
#      so the captain sees the gap instead of the session looping. Any allowed
#      stop resets the count. stop_hook_active is deliberately ignored: Claude
#      sets it on every stop after any hook continuation, including watcher
#      rewakes, so it cannot bound this hook (docs/turnend-guard.md records
#      the same finding for the supervision guard).
#
# The banner carries the literal marker FM_LIVECHECK, which is how
# fm_livecheck_turn_records recognizes the Stop-hook feedback it produces as a
# continuation of the same turn rather than a new one.
#
# State: state/.livecheck-blocks ("session=<id>" then "count=<n>"), written
# atomically; teardown never touches it and deleting it only forgets the count.
#
# Environment:
#   FM_LIVECHECK_BLOCK_BUDGET=2   consecutive blocks per session before the
#                                 warned allow; invalid or zero values use 2
#   FM_HOME / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE  as for every hook
#   FM_LIVECHECK_MAX_WINDOW, FM_LIVECHECK_JIRA_IGNORE  see the library header
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BLOCK_BUDGET=${FM_LIVECHECK_BLOCK_BUDGET:-2}
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=2 ;; esac
BUDGET_FILE="$STATE/.livecheck-blocks"

CLAUDE_MODE=0
for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    *) echo "usage: $(basename "$0") --claude" >&2; exit 2 ;;
  esac
done
if [ "$CLAUDE_MODE" -ne 1 ]; then
  echo "usage: $(basename "$0") --claude" >&2
  exit 2
fi

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
  exit 0
fi
[ ! -e "$CONFIG/livecheck-off" ] || exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# shellcheck source=bin/fm-livecheck-lib.sh
. "$SCRIPT_DIR/fm-livecheck-lib.sh"

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" then (.session_id // "unknown") else "unknown" end' 2>/dev/null) || exit 0
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" then (.transcript_path // "") else "" end' 2>/dev/null) || exit 0
MESSAGE=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" then (.last_assistant_message // "") else "" end' 2>/dev/null) || exit 0
if [ -z "$MESSAGE" ]; then
  [ -n "$TRANSCRIPT" ] || exit 0
  MESSAGE=$(fm_livecheck_final_message "$TRANSCRIPT") || exit 0
  [ -n "$MESSAGE" ] || exit 0
fi

budget_reset() {
  rm -f "$BUDGET_FILE" 2>/dev/null || true
}

ITEMS=$(fm_livecheck_extract_items "$MESSAGE")
if [ -z "$ITEMS" ]; then
  budget_reset
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-livecheck-guard.XXXXXX") || exit 0
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$ITEMS" > "$WORK/items"

system_message() {  # <text>
  printf '%s' "$1" | jq -R -s '{systemMessage: .}'
}

item_lines() {  # <canonical lines> -> "kind id" per line for humans
  printf '%s\n' "$1" | awk -F '\t' 'NF >= 2 { printf "%s %s\n", $1, $2 }'
}

if [ -z "$TRANSCRIPT" ] || ! fm_livecheck_turn_records "$TRANSCRIPT" > "$WORK/records" 2>/dev/null; then
  budget_reset
  system_message "FM_LIVECHECK: could not read this turn's transcript, so these items were not confirmed live: $(item_lines "$ITEMS" | tr '\n' ';')"
  exit 0
fi

VERIFIED=$(fm_livecheck_verified "$WORK/items" "$WORK/records" 2>/dev/null) || VERIFIED=
printf '%s\n' "$VERIFIED" > "$WORK/verified"
UNVERIFIED=$(grep -v -x -F -f "$WORK/verified" "$WORK/items" 2>/dev/null | sed '/^$/d')
if [ -z "$UNVERIFIED" ]; then
  budget_reset
  exit 0
fi

# Consecutive-block accounting for this session.
COUNT=0
if [ -f "$BUDGET_FILE" ]; then
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in ''|*[!0-9]*) old_count=0 ;; esac
  [ "$old_session" = "$SESSION_ID" ] && COUNT=$old_count
fi

ARGS=
while IFS=$'\t' read -r kind id; do
  [ -n "$id" ] || continue
  case "$kind" in
    ref)
      case "$id" in
        '#'*) continue ;;
      esac
      ;;
  esac
  ARGS="$ARGS '$id'"
done <<EOF
$UNVERIFIED
EOF
BARE_REFS=$(printf '%s\n' "$UNVERIFIED" | awk -F '\t' '$1 == "ref" && $2 ~ /^#/ { print $2 }' | tr '\n' ' ')

if [ "$COUNT" -ge "$BLOCK_BUDGET" ]; then
  budget_reset
  system_message "FM_LIVECHECK: the reply still names work not checked live this turn after $COUNT block(s): $(item_lines "$UNVERIFIED" | tr '\n' ';')"
  exit 0
fi

COUNT=$((COUNT + 1))
tmp="$BUDGET_FILE.tmp.$$"
if printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$COUNT" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
fi

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  FM_LIVECHECK: THE REPLY NAMES WORK YOU DID NOT CHECK LIVE THIS TURN\n'
  printf '●  A ledger, status line, backlog note, or memory is history, not status.\n'
  printf '●  Unverified:\n'
  item_lines "$UNVERIFIED" | sed 's/^/●    /'
  if [ -n "$ARGS" ]; then
    printf '●  Check them now with one command, then answer from its result:\n'
    printf '●    %s/bin/fm-verify-items.sh%s\n' "$FM_ROOT" "$ARGS"
  fi
  if [ -n "$BARE_REFS" ]; then
    printf '●  Bare %snames no repository: give the full https:// URL, or check it with\n' "$BARE_REFS"
    printf '●    %s/bin/fm-verify-items.sh --repo <owner/repo> %s\n' "$FM_ROOT" "$BARE_REFS"
  fi
  printf '●  A lookup that ran counts even when it answered not-found or failed: report that result.\n'
  printf '●  Items inside a fenced block, a double-quoted title, or the text of a link to a Confluence or wiki page are exempt; everything else named in the reply is a status claim.\n'
  printf '●  Block %s of %s for this session; after that the reply goes through with a warning to the captain.\n' "$COUNT" "$BLOCK_BUDGET"
  printf '●%s\n' "$rule"
} >&2
exit 2
