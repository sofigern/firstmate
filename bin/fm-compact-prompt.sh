#!/usr/bin/env bash
# fm-compact-prompt.sh - the single owner of the compaction instruction
# firstmate hands the captain when a ticket closes.
# Usage: fm-compact-prompt.sh [--ticket <key>]
# Prints exactly one line, a ready-to-paste `/compact <instruction>` for the
# captain's client, and nothing else. Firstmate cannot compact its own
# context - `/compact` is a client command with no tool behind it - so the
# close's obligation (AGENTS.md section 7) is to hand this line over and
# repeat the ask until the captain has run it.
# bin/fm-teardown.sh prints it after a successful ticket-window teardown.
# Run it directly for the session-scale ask between closes.
# --ticket <key> names the ticket that just closed so the compaction can tell
# that thread is now closed; the key takes the charset bin/fm-brief.sh
# accepts for --ticket. Without it the instruction is generic.
# The instruction's clauses are the captain's own (2026-09-14) and each is
# load-bearing. The last states the direction of loss: a dropped closed-ticket
# detail is recoverable from its report, a dropped open decision is simply
# forgotten. Refine wording here only while keeping every clause.
set -u

usage() { printf 'usage: fm-compact-prompt.sh [--ticket <key>]\n'; }

TICKET=
case "$#" in
  0) ;;
  1)
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --ticket=*) TICKET=${1#--ticket=} ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  2)
    [ "$1" = --ticket ] || { usage >&2; exit 2; }
    TICKET=$2
    ;;
  *) usage >&2; exit 2 ;;
esac
if [ "$#" -gt 0 ] && [ "${1:-}" != --help ] && [ "${1:-}" != -h ]; then
  if ! printf '%s' "$TICKET" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    echo "error: ticket key must use only letters, digits, dot, underscore, and dash (got '$TICKET')" >&2
    exit 2
  fi
fi

PROMPT=
[ -z "$TICKET" ] || PROMPT="Ticket $TICKET has just closed. "
PROMPT+="Drop the detail of tickets that are closed: their investigation steps, intermediate findings, superseded numbers, tool output, and the reasoning that produced conclusions already written into a report, a Jira comment, or a PR. "
PROMPT+="Keep the conclusion only where it still constrains future work. "
PROMPT+="Keep everything that is not durable elsewhere: open decisions waiting on the captain and what each one costs; the state of every live lane and what it is holding; corrections the captain made that have not yet been written to data/captain.md or data/learnings.md; standing instructions he gave this session; and anything firstmate said it would come back to. "
PROMPT+="Keep every claim's provenance: a number without its source is worse after compaction than before, because the source is now unrecoverable. "
PROMPT+="When in doubt, keep an open thread and drop a closed one."
printf '/compact %s\n' "$PROMPT"
