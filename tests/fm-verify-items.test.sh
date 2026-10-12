#!/usr/bin/env bash
# Behavior tests for bin/fm-verify-items.sh, the one-call batch live-status
# check the live-status Stop hook names (docs/livecheck-guard.md).
#
# Every backend is a PATH fake that records its arguments and answers from the
# case's canned data, so the suite covers: the GitHub state and checks mapping,
# GitLab through glab, bare refs falling from pull request to issue, Jira over
# REST and over twg with the status-category mapping, Jenkins with and without
# auth, the unverified and error lines, exit status, stdin input, config/
# livecheck.env sourcing, the per-lookup timeout, usage errors, and that no
# credential ever reaches stdout. No network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verify-items)
command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
BASE_PATH=$PATH
RUN_PATH=
VERIFY="$ROOT/bin/fm-verify-items.sh"

# --- fakes -------------------------------------------------------------------
# Each case gets its own fakebin and log. A fake reads the canned answer for
# the item it was asked about from the case's data dir, so one fake covers many
# shapes without per-case rewrites.

make_case() {  # <name> -> prints the case dir; sets CASE, FAKEBIN, LOG, DATA
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/data" "$CASE/config" "$CASE/state"
  FAKEBIN=$(fm_fakebin "$CASE")
  LOG="$CASE/calls.log"
  DATA="$CASE/data"
  : > "$LOG"
  cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$LOG"
sub=\$1; verb=\$2; target=\$3
file="$DATA/gh-\$sub-\$(printf '%s' "\$target" | tr '/:' '__')"
[ -f "\$file" ] || exit 1
cat "\$file"
SH
  cat > "$FAKEBIN/glab" <<SH
#!/usr/bin/env bash
printf 'glab %s\n' "\$*" >> "$LOG"
[ -f "$DATA/glab-\$3" ] || exit 1
cat "$DATA/glab-\$3"
SH
  cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$LOG"
url=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -u) printf 'auth=%s\n' "\$2" >> "$CASE/auth.seen"; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
key=\$(printf '%s' "\$url" | sed -e 's|[?].*||' -e 's|/api/json\$||' -e 's|.*/||')
[ -f "$DATA/curl-\$key" ] || exit 22
cat "$DATA/curl-\$key"
SH
  cat > "$FAKEBIN/twg" <<SH
#!/usr/bin/env bash
printf 'twg %s\n' "\$*" >> "$LOG"
[ -f "$DATA/twg-\$4" ] || exit 1
cat "$DATA/twg-\$4"
SH
  chmod +x "$FAKEBIN/gh" "$FAKEBIN/glab" "$FAKEBIN/curl" "$FAKEBIN/twg"
  printf '%s\n' "$CASE"
}

run_verify() {  # [args...] -> stdout; status in $?
  PATH="$FAKEBIN:${RUN_PATH:-$BASE_PATH}" FM_CONFIG_OVERRIDE="$CASE/config" FM_STATE_OVERRIDE="$CASE/state" "$VERIFY" "$@" 2>"$CASE/stderr"
}

# A fake removed from fakebin must not fall through to a real host binary:
# this host may have the real tool installed, and then the "absent backend"
# case would quietly make a real network call. Hide it from the base PATH too.
without_tool() {  # <tool>
  RUN_PATH=$(fm_test_base_path_sans "$BASE_PATH" "$1")
  rm -f "$FAKEBIN/$1"
}

pr_json() {  # <state> <isDraft> <mergedAt> <rollup-json> [review]
  jq -n -c --arg s "$1" --argjson d "$2" --arg m "$3" --argjson r "$4" --arg rv "${5:-}" \
    '{state:$s, isDraft:$d, mergedAt:(if $m == "" then null else $m end), closedAt:(if $m == "" then null else $m end),
      mergeStateStatus:"CLEAN", reviewDecision:(if $rv == "" then null else $rv end), statusCheckRollup:$r,
      title:"The title\twith a tab", url:"https://github.com/o/r/pull/1"}'
}

# --- lookup ledger -----------------------------------------------------------

test_lookup_ledger() {
  local out before after ledger
  make_case ledger >/dev/null
  ledger="$CASE/state/.livecheck-ledger"
  pr_json MERGED false 2026-10-10T09:00:00Z '[]' > "$DATA/gh-pr-https___github.com_o_r_pull_1"
  without_tool twg
  before=$(date +%s)
  out=$(run_verify https://github.com/o/r/pull/1 https://github.com/o/r/pull/2 BST-1 | awk -F '\t' '{ print $3 }')
  after=$(date +%s)
  RUN_PATH=
  assert_equals "merged
error
unverified" "$out" "the piped stdout is whatever the consumer made of it"
  out=$(awk -F '\t' -v b="$before" -v a="$after" '$1 >= b && $1 <= a { print $2 "\t" $3 "\t" $4 }' "$ledger")
  assert_equals "pr	https://github.com/o/r/pull/1	merged
pr	https://github.com/o/r/pull/2	error
jira	BST-1	unverified" "$out" "every looked-up item must be recorded with its state and the run's time, whatever consumed stdout"
  awk 'BEGIN { for (i = 1; i <= 600; i++) printf "1\tjira\tOLD-%d\tdone\n", i }' > "$ledger"
  FM_LIVECHECK_LEDGER_MAX=1 run_verify https://github.com/o/r/pull/1 >/dev/null
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 513 ] || fail "an oversized ledger must be trimmed to its newest 512 lines before the append"
  assert_no_grep "OLD-88	" "$ledger" "the oldest lines go first"
  assert_grep 'https://github.com/o/r/pull/1	merged' "$ledger" "the newest lookup survives the trim"
  rm -rf "$CASE/state"
  out=$(run_verify https://github.com/o/r/pull/1); status=$?
  expect_code 0 "$status" "a missing state directory must not fail the lookup"
  assert_contains "$out" "pr	https://github.com/o/r/pull/1	merged" "the lookup still prints without a ledger"
  assert_absent "$CASE/state" "the verifier must not create a state directory"
  [ ! -s "$CASE/stderr" ] || fail "a missing state directory must stay silent: $(cat "$CASE/stderr")"
  pass "fm-verify-items: every lookup is recorded in the state ledger whatever consumes stdout"
}

# --- GitHub ------------------------------------------------------------------

test_github_pr_states_and_checks() {
  local out
  make_case github >/dev/null
  pr_json OPEN false "" '[{"conclusion":"SUCCESS"},{"state":"SUCCESS"}]' APPROVED > "$DATA/gh-pr-https___github.com_o_r_pull_1"
  pr_json OPEN true "" '[{"conclusion":"SUCCESS"},{"conclusion":null}]' > "$DATA/gh-pr-https___github.com_o_r_pull_2"
  pr_json MERGED false 2026-10-10T09:00:00Z '[{"conclusion":"FAILURE"}]' > "$DATA/gh-pr-https___github.com_o_r_pull_3"
  pr_json CLOSED false 2026-10-11T09:00:00Z '[]' > "$DATA/gh-pr-https___github.com_o_r_pull_4"
  out=$(run_verify https://github.com/o/r/pull/1 https://github.com/o/r/pull/2 https://github.com/o/r/pull/3 https://github.com/o/r/pull/4 https://github.com/o/r/pull/5); status=$?
  expect_code 1 "$status" "one unreadable item must make the exit status 1"
  assert_equals "pr	https://github.com/o/r/pull/1	open	merged_at=- closed_at=- checks=pass review=APPROVED mergeable=CLEAN title=\"The title with a tab\" url=https://github.com/o/r/pull/1
pr	https://github.com/o/r/pull/2	draft	merged_at=- closed_at=- checks=pending review=- mergeable=CLEAN title=\"The title with a tab\" url=https://github.com/o/r/pull/1
pr	https://github.com/o/r/pull/3	merged	merged_at=2026-10-10T09:00:00Z closed_at=2026-10-10T09:00:00Z checks=fail review=- mergeable=CLEAN title=\"The title with a tab\" url=https://github.com/o/r/pull/1
pr	https://github.com/o/r/pull/4	closed	merged_at=2026-10-11T09:00:00Z closed_at=2026-10-11T09:00:00Z checks=none review=- mergeable=CLEAN title=\"The title with a tab\" url=https://github.com/o/r/pull/1
pr	https://github.com/o/r/pull/5	error	gh pr view failed (not found, no access, or gh not authenticated)" "$out" "GitHub states, checks, and the error line"
  assert_grep 'gh pr view https://github.com/o/r/pull/1 --json state,isDraft,mergedAt,closedAt,mergeStateStatus,reviewDecision,statusCheckRollup,title,url' "$LOG" "the PR must be read by URL with the status fields"
  pass "fm-verify-items: GitHub pull request states, check rollup, and error line"
}

test_github_issue_and_refs() {
  local out
  make_case refs >/dev/null
  jq -n -c '{state:"CLOSED", stateReason:"COMPLETED", closedAt:"2026-10-01T00:00:00Z", title:"Done thing", url:"https://github.com/o/r/issues/9"}' > "$DATA/gh-issue-https___github.com_o_r_issues_9"
  pr_json OPEN false "" '[]' > "$DATA/gh-pr-12"
  jq -n -c '{state:"OPEN", stateReason:null, closedAt:null, title:"An issue", url:"https://github.com/o/r/issues/13"}' > "$DATA/gh-issue-13"
  out=$(run_verify --repo o/r https://github.com/o/r/issues/9 '#12' '#13' '#14'); status=$?
  expect_code 1 "$status" "an unreadable ref must make the exit status 1"
  assert_equals "issue	https://github.com/o/r/issues/9	closed	reason=COMPLETED closed_at=2026-10-01T00:00:00Z title=\"Done thing\" url=https://github.com/o/r/issues/9
ref	o/r#12	open	merged_at=- closed_at=- checks=none review=- mergeable=CLEAN title=\"The title with a tab\" url=https://github.com/o/r/pull/1
ref	o/r#13	open	reason=- closed_at=- title=\"An issue\" url=https://github.com/o/r/issues/13
ref	o/r#14	error	neither a pull request nor an issue 14 was readable in o/r" "$out" "issue line, ref as PR, ref as issue, and the unreadable ref"
  assert_grep 'gh pr view 13 --repo o/r' "$LOG" "a bound ref must try the pull request first"
  assert_grep 'gh issue view 13 --repo o/r' "$LOG" "a bound ref must fall back to the issue"
  out=$(run_verify '#7'); status=$?
  expect_code 1 "$status" "a bare ref without a repository is unverified"
  assert_equals "ref	#7	unverified	bare #7 names no repository: pass --repo <owner/repo> or the full URL" "$out" "the bare-ref line must say how to bind it"
  out=$(run_verify '#7' https://github.com/o/r/pull/12)
  assert_contains "$out" "ref	o/r#7	" "a single GitHub URL among the items binds a bare ref without --repo"
  pass "fm-verify-items: GitHub issues and bare refs bound by --repo or by the items' one repository"
}

test_gitlab_merge_request() {
  local out
  make_case gitlab >/dev/null
  printf 'title:\tFix the thing\nstate:\tmerged\n' > "$DATA/glab-42"
  out=$(run_verify https://gitlab.example.com/grp/proj/-/merge_requests/42); status=$?
  expect_code 0 "$status" "a readable merge request exits 0"
  assert_equals "pr	https://gitlab.example.com/grp/proj/-/merge_requests/42	merged	title=\"Fix the thing\"" "$out" "the glab state and title"
  assert_grep 'glab mr view 42 -R https://gitlab.example.com/grp/proj' "$LOG" "glab must be addressed by number and project URL"
  without_tool glab
  out=$(run_verify https://gitlab.example.com/grp/proj/-/merge_requests/42)
  RUN_PATH=
  assert_equals "pr	https://gitlab.example.com/grp/proj/-/merge_requests/42	unverified	glab is not installed" "$out" "without glab the merge request is unverified"
  pass "fm-verify-items: GitLab merge requests through glab"
}

# --- Jira --------------------------------------------------------------------

jira_rest_json() {  # <category-key> <status-name> [resolution]
  jq -n -c --arg c "$1" --arg s "$2" --arg r "${3:-}" \
    '{key:"BST-1", fields:{status:{name:$s, statusCategory:{key:$c}}, resolution:(if $r == "" then null else {name:$r} end), summary:"Sum\nmary", updated:"2026-10-10T04:46:45.219-0700"}}'
}

test_jira_rest_backend() {
  local out
  make_case jira-rest >/dev/null
  jira_rest_json 'done' Done Fixed > "$DATA/curl-BST-1"
  jira_rest_json indeterminate 'In Progress' > "$DATA/curl-BST-2"
  jira_rest_json new 'To Do' > "$DATA/curl-BST-3"
  printf 'FM_JIRA_BASE_URL=https://example.atlassian.net/\nFM_JIRA_EMAIL=me@example.invalid\nFM_JIRA_TOKEN=sekrit-token-value\n' > "$CASE/config/livecheck.env"
  out=$(run_verify BST-1 BST-2 BST-3 BST-4); status=$?
  expect_code 1 "$status" "an unreadable key must make the exit status 1"
  assert_equals "jira	BST-1	done	status=\"Done\" resolution=Fixed updated=2026-10-10T04:46:45.219-0700 summary=\"Sum mary\"
jira	BST-2	in-progress	status=\"In Progress\" resolution=none updated=2026-10-10T04:46:45.219-0700 summary=\"Sum mary\"
jira	BST-3	todo	status=\"To Do\" resolution=none updated=2026-10-10T04:46:45.219-0700 summary=\"Sum mary\"
jira	BST-4	error	jira rest lookup failed (curl exit 22)" "$out" "Jira status categories over REST and the error line"
  assert_grep 'https://example.atlassian.net/rest/api/3/issue/BST-1?fields=status,resolution,summary,updated' "$LOG" "REST must be addressed under the configured base URL"
  assert_grep 'auth=me@example.invalid:sekrit-token-value' "$CASE/auth.seen" "the credential must reach curl"
  assert_not_contains "$out" 'sekrit-token-value' "the credential must never reach stdout"
  assert_not_contains "$(cat "$CASE/stderr")" 'sekrit-token-value' "the credential must never reach stderr"
  assert_no_grep 'twg' "$LOG" "REST configured means twg is never consulted"
  pass "fm-verify-items: Jira over REST from config/livecheck.env, credential never printed"
}

test_jira_twg_backend_and_absence() {
  local out
  make_case jira-twg >/dev/null
  jq -n -c '{data:[{key:"BST-5", status:{name:"Done", statusCategory:{key:"done"}}, resolution:{name:"Done"}, summary:"Twg item", updated:"u"}]}' > "$DATA/twg-BST-5"
  out=$(run_verify BST-5); status=$?
  expect_code 0 "$status" "a readable twg item exits 0"
  assert_equals "jira	BST-5	done	status=\"Done\" resolution=Done updated=u summary=\"Twg item\"" "$out" "the twg data shape"
  assert_grep 'twg jira workitem get BST-5 --output json --output-summary none' "$LOG" "twg must be asked for machine-readable JSON"
  out=$(run_verify BST-6)
  assert_equals "jira	BST-6	error	twg lookup failed (exit 1)" "$out" "a twg failure is an error line"
  without_tool twg
  out=$(run_verify BST-5); status=$?
  RUN_PATH=
  expect_code 1 "$status" "no Jira backend exits 1"
  assert_equals "jira	BST-5	unverified	no Jira backend: set FM_JIRA_BASE_URL, FM_JIRA_EMAIL, and FM_JIRA_TOKEN in config/livecheck.env, or install twg" "$out" "the no-backend line names the fix"
  pass "fm-verify-items: Jira through twg, and the unverified line without any backend"
}

# --- Jenkins -----------------------------------------------------------------

test_jenkins_builds_and_auth() {
  local out
  make_case jenkins >/dev/null
  jq -n -c '{building:true, result:null, number:1, timestamp:1760000000000, duration:0, url:"https://ci.example.net/job/a/job/b/1/"}' > "$DATA/curl-1"
  jq -n -c '{building:false, result:"SUCCESS", number:2, timestamp:1760000000000, duration:12345678, url:"https://ci.example.net/job/a/job/b/2/"}' > "$DATA/curl-2"
  jq -n -c '{building:false, result:"UNSTABLE", number:3, timestamp:null, duration:null, url:"https://ci.example.net/job/a/job/b/3/"}' > "$DATA/curl-3"
  out=$(run_verify https://ci.example.net/job/a/job/b/1/ https://ci.example.net/job/a/job/b/2 https://ci.example.net/job/a/job/b/3 https://ci.example.net/job/a/job/b/4); status=$?
  expect_code 1 "$status" "an unreadable build must make the exit status 1"
  assert_equals "jenkins	https://ci.example.net/job/a/job/b/1	building	started=2025-10-09T08:53:20Z duration_s=0 url=https://ci.example.net/job/a/job/b/1/
jenkins	https://ci.example.net/job/a/job/b/2	success	started=2025-10-09T08:53:20Z duration_s=12345 url=https://ci.example.net/job/a/job/b/2/
jenkins	https://ci.example.net/job/a/job/b/3	unstable	started=- duration_s=- url=https://ci.example.net/job/a/job/b/3/
jenkins	https://ci.example.net/job/a/job/b/4	error	jenkins lookup failed (curl exit 22)" "$out" "Jenkins states and the error line"
  assert_grep 'https://ci.example.net/job/a/job/b/1/api/json?tree=building,result,number,timestamp,duration,url' "$LOG" "the build must be read through api/json"
  assert_absent "$CASE/auth.seen" "no credential configured means an anonymous request"
  printf 'user:jenkins-token-value\n' > "$CASE/jenkins-auth"
  printf 'FM_JENKINS_AUTH_FILE=%s\n' "$CASE/jenkins-auth" > "$CASE/config/livecheck.env"
  out=$(run_verify https://ci.example.net/job/a/job/b/2)
  assert_grep 'auth=user:jenkins-token-value' "$CASE/auth.seen" "the auth file must feed basic auth"
  assert_not_contains "$out" 'jenkins-token-value' "the credential must never reach stdout"
  pass "fm-verify-items: Jenkins builds, optional auth file, credential never printed"
}

# --- interface ---------------------------------------------------------------

test_stdin_dedupe_timeout_and_usage() {
  local out
  make_case iface >/dev/null
  pr_json OPEN false "" '[]' > "$DATA/gh-pr-https___github.com_o_r_pull_1"
  out=$(printf 'Captain, https://github.com/o/r/pull/1 and https://github.com/o/r/pull/1 again\n' | run_verify -); status=$?
  expect_code 0 "$status" "items read from stdin"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "duplicates collapse to one line"
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
sleep 5
exit 0
SH
  out=$(run_verify --timeout 1 https://github.com/o/r/pull/1); status=$?
  expect_code 1 "$status" "a lookup past the bound is an error"
  assert_contains "$out" "pr	https://github.com/o/r/pull/1	error" "the bound hit must surface as the error line"
  run_verify >/dev/null; status=$?
  expect_code 2 "$status" "no items is a usage error"
  run_verify --timeout 0 BST-1 >/dev/null; status=$?
  expect_code 2 "$status" "a zero timeout is refused"
  run_verify --repo nope BST-1 >/dev/null; status=$?
  expect_code 2 "$status" "a repository without a slash is refused"
  run_verify --bogus BST-1 >/dev/null; status=$?
  expect_code 2 "$status" "an unknown option is refused"
  run_verify 'just words' >/dev/null; status=$?
  expect_code 2 "$status" "arguments naming no item are a usage error"
  out=$(run_verify --help); status=$?
  expect_code 0 "$status" "--help exits 0"
  assert_contains "$out" 'fm-verify-items.sh [--repo <owner/repo>] [--timeout <seconds>] <item>...' "--help prints the usage"
  pass "fm-verify-items: stdin, deduplication, the per-lookup bound, and usage refusals"
}

test_github_pr_states_and_checks
test_github_issue_and_refs
test_lookup_ledger
test_gitlab_merge_request
test_jira_rest_backend
test_jira_twg_backend_and_absence
test_jenkins_builds_and_auth
test_stdin_dedupe_timeout_and_usage
