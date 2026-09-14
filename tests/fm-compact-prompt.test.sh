#!/usr/bin/env bash
# Behavior tests for bin/fm-compact-prompt.sh: one ready-to-paste /compact line
# carrying every clause of the captain's compaction instruction, an optional
# closed-ticket name, and a refusal of anything else with no line printed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMPT="$ROOT/bin/fm-compact-prompt.sh"

assert_one_compact_line() {
  local out=$1 label=$2
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "$label: expected exactly one line"$'\n'"--- output ---"$'\n'"$out"
  case "$out" in
    "/compact "*) : ;;
    *) fail "$label: the line does not start with '/compact '"$'\n'"--- output ---"$'\n'"$out" ;;
  esac
}

# Every clause the captain named is load-bearing; a rewording that drops one
# fails here even when the line still parses as a /compact command.
assert_every_clause() {
  local out=$1 label=$2
  assert_contains "$out" "Drop the detail of tickets that are closed" "$label: drop-closed clause"
  assert_contains "$out" "investigation steps, intermediate findings, superseded numbers, tool output" "$label: closed-detail inventory"
  assert_contains "$out" "already written into a report, a Jira comment, or a PR" "$label: durable-elsewhere clause"
  assert_contains "$out" "Keep the conclusion only where it still constrains future work" "$label: conclusion clause"
  assert_contains "$out" "Keep everything that is not durable elsewhere" "$label: keep-undurable clause"
  assert_contains "$out" "open decisions waiting on the captain and what each one costs" "$label: open-decisions clause"
  assert_contains "$out" "the state of every live lane and what it is holding" "$label: live-lane clause"
  assert_contains "$out" "corrections the captain made that have not yet been written" "$label: corrections clause"
  assert_contains "$out" "standing instructions he gave this session" "$label: standing-instructions clause"
  assert_contains "$out" "anything firstmate said it would come back to" "$label: come-back clause"
  assert_contains "$out" "Keep every claim's provenance" "$label: provenance clause"
  assert_contains "$out" "the source is now unrecoverable" "$label: provenance rationale"
  assert_contains "$out" "When in doubt, keep an open thread and drop a closed one" "$label: direction-of-loss clause"
}

test_generic_prompt_is_one_pasteable_line() {
  local out
  out=$("$PROMPT") || fail "generic: the script failed"
  assert_one_compact_line "$out" generic
  assert_every_clause "$out" generic
  assert_not_contains "$out" "has just closed" "generic: no ticket was named, so none may be announced as closed"
  pass "the generic prompt is one /compact line carrying every clause"
}

test_ticket_prompt_names_the_closed_ticket() {
  local out out_eq
  out=$("$PROMPT" --ticket KD-2057) || fail "ticket: the script failed"
  assert_one_compact_line "$out" ticket
  assert_every_clause "$out" ticket
  assert_contains "$out" "/compact Ticket KD-2057 has just closed. Drop the detail" "ticket: the closed ticket must open the instruction"
  out_eq=$("$PROMPT" --ticket=KD-2057) || fail "ticket=: the script failed"
  assert_equals "$out" "$out_eq" "ticket: --ticket <key> and --ticket=<key> must print the same line"
  pass "--ticket names the closed ticket ahead of the same clauses"
}

test_bad_arguments_refuse_without_a_line() {
  local out rc
  set +e
  out=$("$PROMPT" --ticket 'KD 2057;rm' 2>/dev/null); rc=$?
  set -e
  expect_code 2 "$rc" "bad-key: an unsafe ticket key must be refused"
  assert_equals "" "$out" "bad-key: a refusal must print no /compact line"
  set +e
  out=$("$PROMPT" --ticket 2>/dev/null); rc=$?
  set -e
  expect_code 2 "$rc" "missing-key: --ticket without a value must be refused"
  assert_equals "" "$out" "missing-key: a refusal must print no /compact line"
  set +e
  out=$("$PROMPT" --bogus 2>/dev/null); rc=$?
  set -e
  expect_code 2 "$rc" "unknown-flag: an unknown flag must be refused"
  assert_equals "" "$out" "unknown-flag: a refusal must print no /compact line"
  set +e
  out=$("$PROMPT" --ticket KD-1 extra 2>/dev/null); rc=$?
  set -e
  expect_code 2 "$rc" "extra-arg: a third argument must be refused"
  assert_equals "" "$out" "extra-arg: a refusal must print no /compact line"
  pass "malformed invocations exit 2 and print no /compact line"
}

test_help_prints_usage_and_exits_zero() {
  local out
  out=$("$PROMPT" --help) || fail "help: --help must exit 0"
  assert_contains "$out" "usage: fm-compact-prompt.sh [--ticket <key>]" "help: usage line"
  assert_not_contains "$out" "/compact" "help: usage must not print a /compact line"
  pass "--help prints usage without a /compact line"
}

test_generic_prompt_is_one_pasteable_line
test_ticket_prompt_names_the_closed_ticket
test_bad_arguments_refuse_without_a_line
test_help_prints_usage_and_exits_zero
