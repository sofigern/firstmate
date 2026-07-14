#!/usr/bin/env bash
# tests/fm-lieutenant.test.sh - the lieutenant flavor of the secondmate mechanism
# (AGENTS.md "one mechanism, two flavors"), Stage 1.
#
# A lieutenant is the per-mission flavor: fm-brief --lieutenant writes the mission
# charter with an auto-idle-then-retire-on-mission-complete definition of done,
# and fm-spawn --lieutenant launches it through the exact secondmate path but with
# an Opus model default, a flavor=lieutenant meta line, and model:/status: fields
# stamped onto the routing-table line. Everything else (kind=secondmate, home,
# launch, sync) is the secondmate mechanism unchanged, so all downstream consumers
# treat a lieutenant as a secondmate with zero changes.
#
# Coverage (must not regress):
#   - charter: mission goal, acceptance-criteria framing, routing scope, marker
#     contract, escalation-to-main-status, and the auto-retire DoD (distinct from
#     the secondmate persistent-idle DoD)
#   - --lieutenant --no-projects and --herdr-lab rejection
#   - the routing-table model:/status: fields parse without breaking the existing
#     home/projects parsers, and are absent on legacy lines
#   - spawn records kind=secondmate + flavor=lieutenant + model=opus, launches in
#     the subhome, and stamps model: opus; status: active idempotently
#   - --model fable overrides the Opus default end to end
#   - a plain --secondmate spawn records NO flavor= and stamps NO model:/status:
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$ROOT/bin/fm-ff-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lieutenant)
export FM_BACKEND=tmux

# --- charter (pure fm-brief) ------------------------------------------------

test_lieutenant_charter_is_mission_scoped() {
  local home brief
  home="$TMP_ROOT/charter-home"
  mkdir -p "$home/data"
  FM_HOME="$home" \
    FM_SECONDMATE_CHARTER='Add OAuth login to yourapp. Acceptance criteria: users sign in via Google and tests cover the happy path.' \
    FM_SECONDMATE_SCOPE='OAuth login work in yourapp' \
    "$ROOT/bin/fm-brief.sh" oauth --lieutenant yourapp >/dev/null 2>&1 \
    || fail "lieutenant charter scaffold failed"
  brief="$home/data/oauth/brief.md"
  assert_present "$brief" "lieutenant charter was not scaffolded"

  assert_grep "You are a lieutenant: a per-mission supervisor" "$brief" \
    "lieutenant charter lost its per-mission role intro"
  assert_grep "Add OAuth login to yourapp." "$brief" "charter dropped the mission goal"
  assert_grep "# Routing scope" "$brief" "charter dropped the routing scope heading"
  assert_grep "OAuth login work in yourapp" "$brief" "charter dropped the routing scope body"
  # Escalation-to-main-status and the from-firstmate marker contract are shared.
  assert_grep "# Escalation to main firstmate" "$brief" "charter dropped the escalation section"
  assert_grep "[fm-from-firstmate]" "$brief" "charter dropped the from-firstmate marker contract"
  # The distinctive auto-idle-then-retire DoD.
  assert_grep "carry this mission to completion, then stand down" "$brief" \
    "charter DoD is not the auto-retire mission contract"
  assert_grep "until the acceptance criteria in your Charter are met" "$brief" \
    "charter DoD dropped the acceptance-criteria completion condition"
  assert_grep "The main firstmate retires you when the mission is complete" "$brief" \
    "charter DoD dropped the firstmate-driven retirement"
  assert_grep "you never tear yourself down" "$brief" \
    "charter DoD dropped the never-self-teardown rule"
  # It must NOT carry the secondmate persistent-idle contract.
  assert_no_grep "You are persistent by default." "$brief" \
    "lieutenant charter wrongly kept the secondmate persistent-idle DoD"
  pass "fm-brief --lieutenant: mission charter with the auto-retire definition of done"
}

test_lieutenant_no_projects_and_herdr_lab_guard() {
  local home brief status
  home="$TMP_ROOT/guard-home"
  mkdir -p "$home/data"

  # Project-less mission (subject is the firstmate repo itself).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-work mission' \
    "$ROOT/bin/fm-brief.sh" selfmission --lieutenant --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--lieutenant --no-projects should exit 0"
  brief="$home/data/selfmission/brief.md"
  assert_grep "None. This is a project-less mission" "$brief" \
    "project-less lieutenant charter used the wrong subject noun"

  # --herdr-lab is rejected for a lieutenant charter, like a secondmate charter.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' \
    "$ROOT/bin/fm-brief.sh" ltherdr --lieutenant firstmate --herdr-lab >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--lieutenant --herdr-lab must be rejected"
  assert_absent "$home/data/ltherdr/brief.md" "rejected --lieutenant --herdr-lab still wrote a brief"

  # Missing projects with no --no-projects still fails loudly, naming --lieutenant.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' \
    "$ROOT/bin/fm-brief.sh" ltnop --lieutenant >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--lieutenant with no projects and no --no-projects must fail"
  pass "fm-brief --lieutenant: --no-projects works and --herdr-lab/omission guards fire"
}

# --- routing-table fields (backward-compatible parsing) ---------------------

test_registry_fields_parse_without_breaking_legacy() {
  local reg
  reg="$TMP_ROOT/secondmates.md"
  cat > "$reg" <<'EOF'
- domain-a - persistent domain (home: /homes/a; scope: triage for a; projects: alpha, beta; added 2026-07-01)
- mission-b - one bounded mission (home: /homes/b; scope: oauth in beta; projects: beta; added 2026-07-02; model: opus; status: active)
EOF
  # Legacy line: home/projects still parse; new fields are absent.
  [ "$(secondmate_registry_field "$reg" domain-a home)" = "/homes/a" ] \
    || fail "legacy line: home no longer parses after adding the field cases"
  [ "$(secondmate_registry_field "$reg" domain-a projects)" = "alpha, beta" ] \
    || fail "legacy line: projects no longer parses"
  secondmate_registry_field "$reg" domain-a model >/dev/null \
    && fail "legacy line: model must be absent (empty)" || true
  secondmate_registry_field "$reg" domain-a status >/dev/null \
    && fail "legacy line: status must be absent (empty)" || true

  # Lieutenant line: the appended fields never break home/projects, and read back.
  [ "$(secondmate_registry_field "$reg" mission-b home)" = "/homes/b" ] \
    || fail "lieutenant line: appended model/status broke the home parser"
  [ "$(secondmate_registry_field "$reg" mission-b projects)" = "beta" ] \
    || fail "lieutenant line: appended model/status broke the projects parser"
  [ "$(secondmate_registry_field "$reg" mission-b model)" = "opus" ] \
    || fail "lieutenant line: model field did not read back"
  [ "$(secondmate_registry_field "$reg" mission-b status)" = "active" ] \
    || fail "lieutenant line: status field did not read back"
  pass "routing table: model:/status: are additive and never break home/projects parsing"
}

# --- spawn (fake tmux + treehouse), one direct-PR project so seed needs no
#     no-mistakes init -------------------------------------------------------

HOME_DIR="$TMP_ROOT/main-home"
SUB="$TMP_ROOT/mission-home"
SUB_ABS=
FAKEBIN=
LOG="$TMP_ROOT/tmux.log"
PANE="$TMP_ROOT/pane.txt"

setup_spawn_world() {
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/state"
  fm_git_init_commit "$HOME_DIR/projects/webapp"
  fm_git_add_origin "$HOME_DIR/projects/webapp" "$TMP_ROOT/remotes/webapp.git"
  cat > "$HOME_DIR/data/projects.md" <<'EOF'
- webapp [direct-PR] - webapp project (added 2026-07-01)
EOF
  FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
  FM_SECONDMATE_SCOPE='webapp oauth mission' \
    scaffold_lieutenant_charter "$HOME_DIR" oauth-mission 'Add OAuth to webapp; acceptance: sign-in works' webapp \
    || fail "lieutenant charter scaffold failed in spawn world"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-home-seed.sh" oauth-mission "$SUB" webapp >/dev/null \
    || fail "lieutenant home seed failed"
  SUB_ABS=$(cd "$SUB" && pwd -P)
}

# fm-brief --lieutenant charter helper (mirrors scaffold_secondmate_charter).
scaffold_lieutenant_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  FM_HOME="$home" FM_SECONDMATE_CHARTER="$charter" "$ROOT/bin/fm-brief.sh" "$id" --lieutenant "$@" >/dev/null
}

spawn_lieutenant() {  # <extra fm-spawn args...>
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/parent-config" \
    FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-spawn.sh" oauth-mission "$SUB" codex --lieutenant "$@"
}

test_spawn_lieutenant_meta_and_registry() {
  local meta reg out
  out=$(spawn_lieutenant) || fail "lieutenant spawn failed"
  assert_contains "$out" "flavor=lieutenant" "spawn message did not advertise the lieutenant flavor"

  meta="$HOME_DIR/state/oauth-mission.meta"
  assert_grep 'kind=secondmate' "$meta" "lieutenant meta must record kind=secondmate (the mechanism)"
  assert_grep 'flavor=lieutenant' "$meta" "lieutenant meta must record flavor=lieutenant"
  assert_grep 'model=opus' "$meta" "lieutenant meta must default the model to opus"
  assert_grep "home=$SUB_ABS" "$meta" "lieutenant meta did not record the subhome"
  assert_grep 'projects=webapp' "$meta" "lieutenant meta did not record the project list"

  # Launched in the subhome through the secondmate path, no project treehouse get.
  assert_grep "FM_HOME='$SUB_ABS'" "$LOG" "lieutenant launch did not set FM_HOME to the subhome"
  assert_no_grep 'treehouse get' "$LOG" "lieutenant spawn ran a project treehouse get"

  # Routing-table line stamped with model/status, and it still parses home/projects.
  reg="$HOME_DIR/data/secondmates.md"
  assert_grep 'model: opus' "$reg" "routing table did not record model: opus"
  assert_grep 'status: active' "$reg" "routing table did not record status: active"
  [ "$(secondmate_registry_field "$reg" oauth-mission home)" = "$SUB_ABS" ] \
    || fail "stamped line broke the home parser"
  [ "$(secondmate_registry_field "$reg" oauth-mission projects)" = "webapp" ] \
    || fail "stamped line broke the projects parser"
  [ "$(secondmate_registry_field "$reg" oauth-mission model)" = "opus" ] \
    || fail "stamped model did not read back"

  # Idempotent: a second spawn does not duplicate the fields.
  spawn_lieutenant >/dev/null 2>&1 || fail "second lieutenant spawn failed"
  [ "$(grep -c 'model:' "$reg")" -eq 1 ] || fail "re-spawn duplicated the model: field"
  [ "$(grep -c 'status:' "$reg")" -eq 1 ] || fail "re-spawn duplicated the status: field"
  pass "fm-spawn --lieutenant: kind=secondmate+flavor+opus meta, idempotent model:/status: stamp"
}

test_spawn_lieutenant_model_override() {
  local meta reg
  spawn_lieutenant --model fable >/dev/null 2>&1 || fail "lieutenant spawn with --model fable failed"
  meta="$HOME_DIR/state/oauth-mission.meta"
  reg="$HOME_DIR/data/secondmates.md"
  assert_grep 'model=fable' "$meta" "--model fable did not override the Opus default in meta"
  assert_no_grep 'model=opus' "$meta" "--model fable left a stale opus default in meta"
  [ "$(secondmate_registry_field "$reg" oauth-mission model)" = "fable" ] \
    || fail "--model fable did not reach the routing table"
  pass "fm-spawn --lieutenant --model fable: Fable overrides the Opus default end to end"
}

test_secondmate_spawn_stays_plain() {
  local sub2 meta reg
  # A plain secondmate seeded and spawned into a fresh home records no flavor and
  # stamps no model:/status:, proving --secondmate is unchanged.
  sub2="$TMP_ROOT/plain-sub"
  FM_SECONDMATE_SCOPE='plain domain' \
    scaffold_secondmate_charter "$HOME_DIR" plaindomain 'a persistent domain' webapp \
    || fail "plain secondmate charter scaffold failed"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-home-seed.sh" plaindomain "$sub2" webapp >/dev/null \
    || fail "plain secondmate seed failed"
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/fm-spawn.sh" plaindomain "$sub2" codex --secondmate >/dev/null 2>&1 \
    || fail "plain secondmate spawn failed"
  meta="$HOME_DIR/state/plaindomain.meta"
  reg="$HOME_DIR/data/secondmates.md"
  assert_grep 'kind=secondmate' "$meta" "plain secondmate meta lost kind=secondmate"
  assert_no_grep 'flavor=' "$meta" "plain secondmate meta wrongly gained a flavor= line"
  # Its registry line carries no lieutenant fields.
  grep -E '^- plaindomain ' "$reg" | grep -q 'model:' \
    && fail "plain secondmate line wrongly gained a model: field" || true
  grep -E '^- plaindomain ' "$reg" | grep -q 'status:' \
    && fail "plain secondmate line wrongly gained a status: field" || true
  pass "fm-spawn --secondmate: unchanged - no flavor= meta, no model:/status: stamp"
}

test_lieutenant_charter_is_mission_scoped
test_lieutenant_no_projects_and_herdr_lab_guard
test_registry_fields_parse_without_breaking_legacy
setup_spawn_world
test_spawn_lieutenant_meta_and_registry
test_spawn_lieutenant_model_override
test_secondmate_spawn_stays_plain
