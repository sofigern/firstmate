#!/usr/bin/env bash
# Behavior tests for the /drydock periodic-compaction skill's safety contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_drydock_skill_safety_contract() {
  local drydock="$ROOT/.agents/skills/drydock/SKILL.md"

  [ -f "$drydock" ] || fail "drydock skill file is missing"
  assert_grep 'user-invocable: true' "$drydock" "drydock skill is not captain-invocable"
  assert_grep 'internal: true' "$drydock" "drydock skill is not flagged internal for installer discovery"
  assert_grep 'backup' "$drydock" "drydock skill does not stage a backup before rewrites"
  assert_grep 'confirms it' "$drydock" "drydock skill does not gate destructive steps on captain confirmation"
  assert_grep 'unlanded work' "$drydock" "drydock skill does not check dropped clones for unlanded work"
  assert_grep 'Do not guess which projects are alive; ask.' "$drydock" "drydock skill does not make the project interview interactive"
  assert_grep 'never assume or hardcode any particular operator' "$drydock" "drydock skill hardcodes operator-global config paths"
  assert_grep 'fable' "$drydock" "drydock skill does not state its heavy-reasoning model requirement"
  assert_grep "section 6's knowledge-routing table" "$drydock" "drydock skill does not defer placement to the one-owner routing table"
  pass "drydock skill safety contract holds"
}

test_drydock_trigger_declared_inline() {
  local agents="$ROOT/AGENTS.md"

  # shellcheck disable=SC2016  # single quotes are deliberate: literal backtick-quoted text, not an expansion
  assert_grep 'When the captain invokes `/drydock` or asks for the weekly compaction, load the `drydock` skill.' "$agents" "AGENTS.md does not declare the drydock load trigger"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal backtick-quoted text, not an expansion
  assert_grep '`/drydock`' "$ROOT/README.md" "README does not list /drydock among built-in skills"
  pass "drydock trigger is declared inline in AGENTS.md and README"
}

test_stow_cross_references_drydock_graduation() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep '/drydock' "$stow" "stow scope exclusion does not point to drydock as the deliberate skill path"
  pass "stow cross-references drydock's graduation step"
}

test_drydock_skill_safety_contract
test_drydock_trigger_declared_inline
test_stow_cross_references_drydock_graduation
