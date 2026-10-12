#!/usr/bin/env bash
# Behavior tests for the live-status Stop hook (docs/livecheck-guard.md).
#
# Three layers:
#   EXTRACT  - bin/fm-livecheck-lib.sh fm_livecheck_extract_items: which work
#              items a captain-facing reply names, and which tokens are noise.
#   TURN     - fm_livecheck_turn_records / fm_livecheck_final_message over
#              Claude-shaped JSONL transcripts: where the turn starts, which
#              Stop-hook feedback continues it, and the growing tail read.
#   VERIFY   - fm_livecheck_verified: which turn records count as a live
#              lookup of which item, and which never do.
#   HOOK     - bin/fm-livecheck-guard.sh --claude end to end over a fake
#              primary home: silence, block banner and command, budget and the
#              warned allow, transcript fallback, scope and host stand-downs,
#              and the tracked .claude/settings.json registration.
# All hermetic over temp dirs; no real agent session and no network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-livecheck-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-livecheck-guard)
fm_git_identity fmtest fmtest@example.invalid
command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

PR_URL='https://github.com/tubular/tbcode/pull/25005'
JIRA_KEY='BST-2136'
JENKINS_URL='https://jobs.example.net/job/prod-video-loader/job/notify/12884'

# --- transcript builders ----------------------------------------------------
# Each prints one Claude-shaped JSONL line, matching the entry shapes observed
# in real transcripts (docs/livecheck-guard.md "Transcript facts").

t_prompt() {  # <text> [origin-kind]
  jq -n -c --arg t "$1" --arg k "${2:-human}" \
    '{type:"user", isSidechain:false, origin:{kind:$k}, message:{role:"user", content:$t}}'
}

t_prompt_blocks() {  # <text>  (array-shaped prompt with a text block)
  jq -n -c --arg t "$1" '{type:"user", message:{role:"user", content:[{type:"text", text:$t}]}}'
}

t_meta() {  # <text>  (a skill load or image attachment, never a boundary)
  jq -n -c --arg t "$1" '{type:"user", isMeta:true, message:{role:"user", content:[{type:"text", text:$t}]}}'
}

t_tool_use() {  # <id> <name> <input-json>
  jq -n -c --arg i "$1" --arg n "$2" --argjson in "$3" \
    '{type:"assistant", isSidechain:false, message:{role:"assistant", content:[{type:"tool_use", id:$i, name:$n, input:$in}]}}'
}

t_bash() {  # <id> <command>
  t_tool_use "$1" Bash "$(jq -n -c --arg c "$2" '{command:$c, description:"test"}')"
}

t_result() {  # <id> <text> [is_error]
  jq -n -c --arg i "$1" --arg t "$2" --argjson e "${3:-false}" \
    '{type:"user", isSidechain:false, toolUseResult:{}, message:{role:"user", content:[{type:"tool_result", tool_use_id:$i, is_error:$e, content:$t}]}}'
}

t_result_blocks() {  # <id> <text>  (array-shaped result content)
  jq -n -c --arg i "$1" --arg t "$2" \
    '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:$i, content:[{type:"text", text:$t}]}]}}'
}

t_text() {  # <text>
  jq -n -c --arg t "$1" '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}]}}'
}

t_thinking() {
  jq -n -c '{type:"assistant", message:{role:"assistant", content:[{type:"thinking", thinking:"..."}]}}'
}

t_noise() {  # the non-message entry kinds real transcripts carry
  printf '%s\n' '{"type":"attachment","attachment":{"type":"hook_success"}}' \
    '{"type":"system","subtype":"stop_hook_summary"}' \
    '{"type":"last-prompt","content":"x"}' \
    '{"type":"queue-operation","operation":"enqueue"}'
}

t_stop_feedback() {  # <body>
  t_prompt "$(printf '<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\nStop hook blocking error from command "Stop": %s\n</system-reminder>\n' "$1")" task-notification
}

t_sidechain_bash() {  # <id> <command>
  jq -n -c --arg i "$1" --arg c "$2" \
    '{type:"assistant", isSidechain:true, message:{role:"assistant", content:[{type:"tool_use", id:$i, name:"Bash", input:{command:$c}}]}}'
}

records_of() {  # <transcript>
  fm_livecheck_turn_records "$1"
}

names_in() {  # <records-jsonl> -> tool names, one per line
  printf '%s\n' "$1" | jq -r '.name'
}

verified_for() {  # <items-text> <records-text>
  local dir
  dir=$(mktemp -d "$TMP_ROOT/verify.XXXXXX")
  printf '%s\n' "$1" > "$dir/items"
  printf '%s\n' "$2" > "$dir/records"
  fm_livecheck_verified "$dir/items" "$dir/records"
}

record() {  # <name> <input-json> <result-text> [error]
  jq -n -c --arg n "$1" --arg i "$2" --arg r "$3" --argjson e "${4:-false}" '{name:$n, input:$i, result:$r, error:$e}'
}

bash_record() {  # <command> <result-text> [error]
  record Bash "$(jq -n -c --arg c "$1" '{command:$c}')" "$2" "${3:-false}"
}

# --- EXTRACT -----------------------------------------------------------------

test_extract_names_every_kind_once() {
  local out
  out=$(fm_livecheck_extract_items "Captain, **$JIRA_KEY** and $PR_URL/files are open; the deploy $JENKINS_URL/ is green (see https://github.com/tubular/tbcode/issues/9).
Also https://tubularlabs.atlassian.net/browse/BST-1806?focused=1 and https://gitlab.example.com/grp/sub/proj/-/merge_requests/42, and #108 is the PR.
Again $JIRA_KEY, \`$PR_URL\`.")
  assert_equals "jira	$JIRA_KEY
pr	$PR_URL
jenkins	$JENKINS_URL
issue	https://github.com/tubular/tbcode/issues/9
jira	BST-1806
pr	https://gitlab.example.com/grp/sub/proj/-/merge_requests/42
ref	tubular/tbcode#108" "$out" "extraction must canonicalize each kind once, in first-mention order, refs last"
  pass "fm_livecheck_extract_items: every item kind, canonical and deduplicated"
}

test_extract_skips_fences_and_technical_tokens() {
  local out
  out=$(fm_livecheck_extract_items "Captain, the draft reads:
\`\`\`
BST-9999 and https://github.com/x/y/pull/1 are quoted here
\`\`\`
UTF-8, SHA-256, CVE-2024-1234, ISO-8601, Q3-2026, RFC-2119, U+2063 and X-1 are not tickets.
~~~sh
gh pr view 77 --repo a/b
~~~
BST-1 is.")
  assert_equals "jira	BST-1" "$out" "fenced blocks and technical tokens must be ignored"
  out=$(fm_livecheck_extract_items "Captain, shipshape.")
  [ -z "$out" ] || fail "a reply without work items extracted: $out"
  pass "fm_livecheck_extract_items: fenced blocks are exempt and technical tokens are not Jira keys"
}

test_extract_binds_bare_refs() {
  local out
  out=$(fm_livecheck_extract_items "#5 and #6, then #5 again" sofigern/firstmate)
  assert_equals "ref	sofigern/firstmate#5
ref	sofigern/firstmate#6" "$out" "--repo must bind bare refs"
  out=$(fm_livecheck_extract_items "#5 https://github.com/a/b/pull/1 https://github.com/c/d/pull/2")
  assert_contains "$out" "ref	#5" "two repositories in the reply must leave a bare ref unbound"
  out=$(fm_livecheck_extract_items "see #5")
  assert_equals "ref	#5" "$out" "no repository context must leave a bare ref unbound"
  out=$(fm_livecheck_extract_items "https://github.com/a/b/issues/3 fixes #4")
  assert_contains "$out" "ref	a/b#4" "an issue URL is repository context for a bare ref"
  pass "fm_livecheck_extract_items: bare refs bind to the single repository in context or stay bare"
}

test_extract_rejects_malformed_urls() {
  local out
  out=$(fm_livecheck_extract_items "https://github.com/o/r/pull/0 https://github.com/o/r/pulls https://example.com/job/a https://github.com/a--b/r/pull/3")
  [ -z "$out" ] || fail "malformed URLs were extracted: $out"
  pass "fm_livecheck_extract_items: malformed URLs are not items"
}

test_extract_skips_quoted_titles_and_wiki_link_text() {
  local out
  out=$(fm_livecheck_extract_items "Captain, the 2015 Confluence page \"TEP-22: Trends Service\" describes the design; BST-1 is the ticket.")
  assert_equals "jira	BST-1" "$out" "a key inside a straight double-quoted title is not a claim; the bare key beside it is"
  local lq rq
  lq=$(printf '\342\200\234'); rq=$(printf '\342\200\235')
  out=$(fm_livecheck_extract_items "The page ${lq}TEP-22: Trends Service${rq} and the PR ${lq}https://github.com/a/b/pull/9${rq} are quoted, BST-2 is not.")
  assert_equals "jira	BST-2" "$out" "a curly double-quoted span is exempt for every item kind"
  out=$(fm_livecheck_extract_items "The worker said \"ready\" and https://github.com/a/b/pull/7 is green \"now\".")
  assert_equals "pr	https://github.com/a/b/pull/7" "$out" "quotes pair left to right, so prose between two quoted words stays a claim"
  out=$(fm_livecheck_extract_items "He wrote \"TEP-22 is the design and BST-3 the ticket")
  assert_equals "jira	TEP-22
jira	BST-3" "$out" "an unbalanced quote exempts nothing"
  out=$(fm_livecheck_extract_items "See [TEP-22: Trends Service](https://tubularlabs.atlassian.net/wiki/spaces/ENG/pages/123/TEP-22) and [TEP-23 design](https://confluence.example.com/display/ENG/Trends).")
  [ -z "$out" ] || fail "the text of a link to a Confluence or wiki page must not be a claim: $out"
  out=$(fm_livecheck_extract_items "See [TEP-22: Trends Service](https://tubularlabs.atlassian.net/browse/TEP-22) and [BST-4 fix](https://github.com/a/b/pull/4) and [TEP-25](https://example.com/pages/1).")
  assert_equals "jira	TEP-22
jira	BST-4
pr	https://github.com/a/b/pull/4
jira	TEP-25" "$out" "a link to any other target keeps its text as prose and still reads the target"
  out=$(fm_livecheck_extract_items "TEP-22 and \`TEP-24\` are claims.")
  assert_equals "jira	TEP-22
jira	TEP-24" "$out" "a bare key and a key in inline code remain claims"
  pass "fm_livecheck_extract_items: quoted titles and Confluence or wiki link text are not claims, bare keys are"
}

# --- TURN --------------------------------------------------------------------

test_turn_records_start_after_newest_prompt() {
  local t out names
  t="$TMP_ROOT/turn-basic.jsonl"
  {
    t_prompt "old turn"
    t_bash old1 "gh pr view 1"
    t_result old1 "state"
    t_text "old reply"
    t_noise
    t_prompt "newest turn"
    t_meta "Base directory for this skill: x"
    t_thinking
    t_bash new1 "gh pr view 2 --repo o/r"
    t_result new1 '{"state":"MERGED"}'
    t_sidechain_bash side1 "gh pr view 3"
    t_tool_use new2 mcp__x__getJiraIssue '{"issueIdOrKey":"BST-1"}'
    t_result_blocks new2 'BST-1 Done'
    t_bash new3 "false"
    t_result new3 "boom" true
    t_bash new4 "no result yet"
    printf '%s\n' 'not json at all'
    t_text "final"
    t_noise
  } > "$t"
  out=$(records_of "$t") || fail "turn records failed on a well-formed transcript"
  names=$(printf '%s\n' "$out" | jq -r '[.name, (.input | fromjson | (.command // .issueIdOrKey)), .result, .error] | @tsv')
  assert_equals "Bash	gh pr view 2 --repo o/r	{\"state\":\"MERGED\"}	false
mcp__x__getJiraIssue	BST-1	BST-1 Done	false
Bash	false	boom	true
Bash	no result yet		false" "$names" "records must cover only the newest turn, joined with results, main chain only"
  pass "fm_livecheck_turn_records: newest prompt bounds the turn; meta, sidechain, noise, and bad lines are ignored"
}

test_turn_records_treat_guard_feedback_as_continuation() {
  local t out guard_dir banner
  guard_dir=$(make_primary_dir "$TMP_ROOT/real-guard")
  cp "$ROOT/bin/fm-turnend-guard.sh" "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-wake-lib.sh" \
    "$ROOT/bin/fm-supervision-instructions.sh" "$ROOT/bin/fm-harness.sh" "$ROOT/bin/fm-operational-input.sh" "$guard_dir/bin/"
  mkdir -p "$guard_dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$guard_dir/docs/supervision-protocols"
  : > "$guard_dir/state/task1.meta"
  # The real supervision guard's block banner, produced by the real script, so
  # the continuation rule is pinned to what that guard actually prints.
  banner=$(printf '{"stop_hook_active":false}' | FM_HOME="$guard_dir" bash "$guard_dir/bin/fm-turnend-guard.sh" 2>&1 >/dev/null)
  case "$banner" in *'TURN WOULD END BLIND'*) ;; *) fail "the supervision guard fixture did not block: $banner" ;; esac

  t="$TMP_ROOT/turn-continuation.jsonl"
  {
    t_prompt "captain asks"
    t_bash a1 "gh pr view 7 --repo o/r"
    t_result a1 "x"
    t_text "reply one"
    t_stop_feedback "$(printf '●  FM_LIVECHECK: THE REPLY NAMES WORK YOU DID NOT CHECK LIVE THIS TURN\n●  Unverified: jira BST-1')"
    t_bash a2 "twg jira workitem get BST-1 --output json"
    t_result a2 "y"
    t_text "reply two"
    t_stop_feedback "$banner"
    t_bash a3 "bin/fm-watch-arm.sh"
    t_result a3 "z"
    t_text "reply three"
  } > "$t"
  out=$(records_of "$t" | jq -r '.input | fromjson | .command')
  assert_equals "gh pr view 7 --repo o/r
twg jira workitem get BST-1 --output json
bin/fm-watch-arm.sh" "$out" "both guard feedbacks must continue the turn"

  {
    t_prompt "captain asks"
    t_bash b1 "gh pr view 7 --repo o/r"
    t_result b1 "x"
    t_text "reply one"
    t_stop_feedback "firstmate watcher wake - one supervision event needs a handling turn now.
check: rearm-resurface"
    t_bash b2 "bin/fm-wake-drain.sh"
    t_result b2 "drained"
    t_text "reply two"
  } > "$t"
  out=$(records_of "$t" | jq -r '.input | fromjson | .command')
  assert_equals "bin/fm-wake-drain.sh" "$out" "a watcher rewake must start a new turn"

  {
    t_prompt "captain asks"
    t_bash c1 "gh pr view 7 --repo o/r"
    t_result c1 "x"
    t_prompt "[Request interrupted by user]" ""
    t_prompt_blocks "typed with an image attached"
    t_bash c2 "gh pr view 8 --repo o/r"
    t_result c2 "y"
  } > "$t"
  out=$(records_of "$t" | jq -r '.input | fromjson | .command')
  assert_equals "gh pr view 8 --repo o/r" "$out" "an interruption and a block-shaped prompt are boundaries"
  pass "fm_livecheck_turn_records: guard feedback continues the turn, every other prompt starts one"
}

test_turn_records_grow_the_tail_window() {
  local t out pad first_tail
  t="$TMP_ROOT/turn-wide.jsonl"
  pad=$(head -c 300000 /dev/zero | tr '\0' 'x')
  {
    t_prompt "the only prompt"
    t_bash w1 "gh pr view 9 --repo o/r"
    t_result w1 "y"
    # Five ~300 KiB noise entries push the prompt well past the first 1 MiB tail.
    for _ in 1 2 3 4 5; do
      printf '{"type":"attachment","attachment":{"content":"%s"}}\n' "$pad" # printf is a builtin: a 300 KB jq --arg exceeds Linux's per-argument limit
    done
    t_text "final"
  } > "$t"
  first_tail=$(tail -c 1048576 "$t" | sed '1d' | grep -c '"the only prompt"' || true)
  [ "$first_tail" -eq 0 ] || fail "fixture is vacuous: the prompt sits inside the first 1 MiB tail"
  out=$(records_of "$t" | jq -r '.input | fromjson | .command')
  assert_equals "gh pr view 9 --repo o/r" "$out" "the reader must widen its tail until the prompt is found"

  # With the window capped below the prompt the tail itself is the turn.
  out=$(FM_LIVECHECK_MAX_WINDOW=1048576 records_of "$t" | wc -l | tr -d ' ')
  assert_equals 0 "$out" "a capped window with no prompt yields the tail's own (empty) records"
  pass "fm_livecheck_turn_records: the tail window grows until a prompt is found and is bounded by the cap"
}

test_turn_records_unreadable_transcript_fails() {
  if records_of "$TMP_ROOT/does-not-exist.jsonl" >/dev/null 2>&1; then
    fail "a missing transcript must fail the reader"
  fi
  pass "fm_livecheck_turn_records: a missing transcript returns failure, never an empty turn"
}

test_final_message_is_trailing_assistant_text() {
  local t out
  t="$TMP_ROOT/final.jsonl"
  {
    t_prompt "ask"
    t_text "Let me check."
    t_bash f1 "gh pr view 1"
    t_result f1 "x"
    t_thinking
    t_text "Captain, line one."
    t_text "Line two."
    t_noise
  } > "$t"
  out=$(fm_livecheck_final_message "$t")
  assert_equals "Captain, line one.
Line two." "$out" "the final message is every text block after the last tool result"
  pass "fm_livecheck_final_message: trailing assistant text after the last tool result"
}

# --- VERIFY ------------------------------------------------------------------

test_verified_github_lookups() {
  local items out
  items="pr	$PR_URL
issue	https://github.com/tubular/tbcode/issues/9
ref	tubular/tbcode#108
ref	#77"
  out=$(verified_for "$items" "$(bash_record 'gh pr view 25005 --repo tubular/tbcode --json state' '{"state":"OPEN"}')")
  assert_equals "pr	$PR_URL" "$out" "gh pr view by number with the same --repo verifies the PR"
  out=$(verified_for "$items" "$(bash_record 'gh-axi pr view 25005 --repo other/repo' 'x')")
  [ -z "$out" ] || fail "a different --repo must not verify the PR: $out"
  out=$(verified_for "$items" "$(bash_record "gh pr view $PR_URL --json state" '{"state":"MERGED"}')")
  assert_equals "pr	$PR_URL" "$out" "gh pr view by URL verifies the PR"
  out=$(verified_for "$items" "$(bash_record 'gh api repos/tubular/tbcode/pulls/25005' '{"state":"open"}')")
  assert_equals "pr	$PR_URL" "$out" "a read-only gh api pulls path verifies the PR"
  out=$(verified_for "$items" "$(bash_record 'gh api -X POST repos/tubular/tbcode/pulls/25005/comments -f body=hi' '{}')")
  [ -z "$out" ] || fail "a gh api write must not count as a lookup: $out"
  out=$(verified_for "$items" "$(bash_record 'gh issue view 9 --repo tubular/tbcode' 'open')")
  assert_equals "issue	https://github.com/tubular/tbcode/issues/9" "$out" "gh issue view verifies the issue"
  out=$(verified_for "$items" "$(bash_record 'gh pr view 108 --repo tubular/tbcode' 'x')")
  assert_equals "ref	tubular/tbcode#108" "$out" "a bound ref is verified by its number under its repository"
  out=$(verified_for "$items" "$(bash_record 'gh pr checks 77 --repo whatever/repo' 'x')")
  assert_equals "ref	#77" "$out" "an unbound ref is verified by its number under any repository"
  out=$(verified_for "$items" "$(bash_record 'gh pr list --repo tubular/tbcode --json url' "[{\"url\":\"$PR_URL\"}]")")
  assert_equals "pr	$PR_URL" "$out" "a list whose result carries the URL verifies the PR"
  out=$(verified_for "$items" "$(bash_record "cat data/backlog.md" "- $PR_URL open")")
  [ -z "$out" ] || fail "reading a ledger that mentions the URL must not count: $out"
  out=$(verified_for "$items" "$(bash_record 'gh pr view 25005 --repo tubular/tbcode' 'could not resolve to a PullRequest' true)")
  assert_equals "pr	$PR_URL" "$out" "a lookup that ran and failed (not found) still counts: it is a live answer"
  out=$(verified_for "$items" "$(record mcp__github__get_pull_request '{"owner":"tubular","repo":"tbcode","pullNumber":25005}' "{\"html_url\":\"$PR_URL\"}")")
  assert_equals "pr	$PR_URL" "$out" "a GitHub MCP read whose result carries the URL verifies the PR"
  pass "fm_livecheck_verified: GitHub reads count whatever they answered, writes and ledger reads do not"
}

test_verified_jira_jenkins_gitlab_lookups() {
  local items out
  items="jira	$JIRA_KEY
jenkins	$JENKINS_URL
pr	https://gitlab.example.com/grp/proj/-/merge_requests/42"
  out=$(verified_for "$items" "$(record mcp__claude_ai_Atlassian_Rovo__getJiraIssue "{\"issueIdOrKey\":\"$JIRA_KEY\"}" 'In Progress')")
  assert_equals "jira	$JIRA_KEY" "$out" "an MCP getJiraIssue on the key verifies it"
  out=$(verified_for "$items" "$(record mcp__x__searchJiraIssuesUsingJql '{"jql":"project = BST"}' "$JIRA_KEY Done")")
  assert_equals "jira	$JIRA_KEY" "$out" "a JQL search whose result carries the key verifies it"
  out=$(verified_for "$items" "$(record mcp__x__addCommentToJiraIssue "{\"issueIdOrKey\":\"$JIRA_KEY\"}" 'ok')")
  [ -z "$out" ] || fail "a Jira write must not count: $out"
  out=$(verified_for "$items" "$(bash_record "twg jira workitem get $JIRA_KEY --output json" '{"key":"x"}')")
  assert_equals "jira	$JIRA_KEY" "$out" "twg jira workitem get verifies the key"
  out=$(verified_for "$items" "$(bash_record "grep $JIRA_KEY data/backlog.md" "$JIRA_KEY open")")
  [ -z "$out" ] || fail "grepping a ledger for the key must not count: $out"
  out=$(verified_for "$items" "$(bash_record "twg jira workitem get BST-21360 --output json" 'x')")
  [ -z "$out" ] || fail "a longer key must not verify a shorter one: $out"
  # shellcheck disable=SC2016 # the literal $J is part of the recorded command under test
  out=$(verified_for "$items" "$(bash_record 'J=https://jobs.example.net/job/prod-video-loader/job/notify; curl -s "$J/12884/api/json?tree=result"' "{\"url\":\"$JENKINS_URL/\",\"result\":\"SUCCESS\"}")")
  assert_equals "jenkins	$JENKINS_URL" "$out" "an api/json read whose result carries the build URL verifies it"
  out=$(verified_for "$items" "$(bash_record 'tb-jenkins -c prod info notify 12884' '{"result":"SUCCESS"}')")
  assert_equals "jenkins	$JENKINS_URL" "$out" "tb-jenkins info <job> <n> verifies the build"
  out=$(verified_for "$items" "$(bash_record 'tb-jenkins info notify 1288' 'x')")
  [ -z "$out" ] || fail "a build number prefix must not verify: $out"
  out=$(verified_for "$items" "$(bash_record 'curl -s https://jobs.example.net/api/json' "$JENKINS_URL")")
  assert_equals "jenkins	$JENKINS_URL" "$out" "any api/json read naming the build URL verifies it"
  out=$(verified_for "$items" "$(bash_record 'glab mr view 42 -R https://gitlab.example.com/grp/proj' 'state: merged')")
  assert_equals "pr	https://gitlab.example.com/grp/proj/-/merge_requests/42" "$out" "glab mr view verifies the merge request"
  pass "fm_livecheck_verified: Jira, Jenkins, and GitLab reads count by what they are"
}

test_verified_helper_lines_and_compound_commands() {
  local items out
  items="pr	$PR_URL
pr	https://github.com/tubular/tbcode/pull/2500
jira	$JIRA_KEY"
  out=$(verified_for "$items" "$(bash_record "bin/fm-verify-items.sh $PR_URL $JIRA_KEY" "pr	$PR_URL	merged	merged_at=x
jira	$JIRA_KEY	error	twg lookup failed (exit 1)" true)")
  assert_equals "pr	$PR_URL
jira	$JIRA_KEY" "$out" "a helper line in any real state verifies its exact item, including an error line from a lookup that ran"
  out=$(verified_for "$items" "$(bash_record "bin/fm-verify-items.sh $PR_URL $JIRA_KEY" "pr	$PR_URL	open	x
jira	$JIRA_KEY	unverified	no Jira backend: install twg" true)")
  assert_equals "pr	$PR_URL" "$out" "an unverified helper line means no lookup ran, so it never counts"
  out=$(verified_for "$items" "$(bash_record "bin/fm-verify-items.sh $JIRA_KEY" "fm-verify-items.sh: --repo needs <owner/repo>" true)")
  [ -z "$out" ] || fail "a helper run that printed no line for the item must not count: $out"
  out=$(verified_for "$items" "$(bash_record "bin/fm-verify-items.sh https://github.com/tubular/tbcode/pull/2500" "pr	https://github.com/tubular/tbcode/pull/2500	open	x")")
  assert_equals "pr	https://github.com/tubular/tbcode/pull/2500" "$out" "a helper line for pull/2500 must not verify pull/25005"
  out=$(verified_for "$items" "$(bash_record "gh pr view 25005 --repo tubular/tbcode; twg jira workitem get $JIRA_KEY" 'x')")
  assert_equals "pr	$PR_URL
jira	$JIRA_KEY" "$out" "one command carrying two lookups verifies both items"
  pass "fm_livecheck_verified: helper output lines and compound commands"
}

# --- HOOK --------------------------------------------------------------------

install_hook_scripts() {
  local dir=$1 script
  mkdir -p "$dir/bin"
  for script in fm-livecheck-guard.sh fm-livecheck-lib.sh fm-pr-lib.sh fm-primary-scope-lib.sh fm-hook-host-lib.sh; do
    cp "$ROOT/bin/$script" "$dir/bin/$script"
  done
  chmod +x "$dir/bin/fm-livecheck-guard.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_hook_scripts "$dir"
  printf '%s\n' "$dir"
}

make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/livecheck-guard-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_hook_scripts "$dir"
  printf '%s\n' "$dir"
}

payload() {  # <session> <transcript> <message>
  jq -n -c --arg s "$1" --arg t "$2" --arg m "$3" \
    '{session_id:$s, hook_event_name:"Stop", stop_hook_active:false, transcript_path:$t, last_assistant_message:$m}'
}

run_hook() {  # <dir> <payload-json> -> stdout+stderr, status in $?
  local dir=$1
  printf '%s' "$2" | CLAUDECODE=1 FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1
}

write_unverified_transcript() {  # <path>
  {
    t_prompt "what is open"
    t_bash u1 "cat data/backlog.md"
    t_result u1 "- $PR_URL open
- $JIRA_KEY in progress"
    t_text "Captain, $PR_URL and $JIRA_KEY are still open."
  } > "$1"
}

write_verified_transcript() {  # <path>
  {
    t_prompt "what is open"
    t_bash v1 "bin/fm-verify-items.sh $PR_URL $JIRA_KEY"
    t_result v1 "pr	$PR_URL	merged	merged_at=2026-10-10T09:00:00Z
jira	$JIRA_KEY	done	status=\"Done\""
    t_text "Captain, $PR_URL merged and $JIRA_KEY is done."
  } > "$1"
}

MESSAGE="Captain, $PR_URL and $JIRA_KEY are still open."

test_hook_silent_without_items_or_payload() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-silent")
  write_unverified_transcript "$dir/t.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" 'Captain, shipshape.')"); status=$?
  expect_code 0 "$status" "a reply without work items must end the turn"
  [ -z "$out" ] || fail "no-item reply produced output: $out"
  out=$(printf '' | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1); status=$?
  expect_code 0 "$status" "an empty payload must be allowed"
  [ -z "$out" ] || fail "empty payload produced output: $out"
  out=$(printf 'not json' | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1); status=$?
  expect_code 0 "$status" "a malformed payload must be allowed"
  pass "fm-livecheck-guard: silent with no work items, no payload, or a malformed payload"
}

test_hook_blocks_unverified_with_banner_and_command() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-block")
  write_unverified_transcript "$dir/t.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 2 "$status" "unverified items must block the stop"
  assert_contains "$out" 'FM_LIVECHECK' "banner must carry the continuation marker"
  assert_contains "$out" "pr $PR_URL" "banner must name the unverified PR"
  assert_contains "$out" "jira $JIRA_KEY" "banner must name the unverified Jira key"
  assert_contains "$out" "$dir/bin/fm-verify-items.sh '$PR_URL' '$JIRA_KEY'" "banner must give the one verifier command"
  assert_contains "$out" 'Block 1 of 2' "banner must show the budget position"
  assert_equals "session=s1
count=1" "$(cat "$dir/state/.livecheck-blocks")" "the block must be recorded for this session"
  pass "fm-livecheck-guard: blocks with the item list and the one verifier command"
}

test_hook_allows_verified_and_resets_budget() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-verified")
  write_verified_transcript "$dir/t.jsonl"
  printf 'session=s1\ncount=1\n' > "$dir/state/.livecheck-blocks"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "Captain, $PR_URL merged and $JIRA_KEY is done.")"); status=$?
  expect_code 0 "$status" "a reply whose items were checked this turn must end the turn"
  [ -z "$out" ] || fail "verified reply produced output: $out"
  assert_absent "$dir/state/.livecheck-blocks" "an allowed stop must reset the block count"
  pass "fm-livecheck-guard: allows a reply whose items were checked live this turn"
}

test_hook_partial_verification_names_only_the_rest() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-partial")
  {
    t_prompt "what is open"
    t_bash p1 "gh pr view 25005 --repo tubular/tbcode --json state"
    t_result p1 '{"state":"OPEN"}'
    t_text "$MESSAGE"
  } > "$dir/t.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 2 "$status" "one unverified item still blocks"
  assert_not_contains "$out" "pr $PR_URL" "the checked PR must not be listed"
  assert_contains "$out" "jira $JIRA_KEY" "the unchecked key must be listed"
  assert_contains "$out" "fm-verify-items.sh '$JIRA_KEY'" "the command must carry only the unchecked items"
  pass "fm-livecheck-guard: a partially checked reply is blocked for the rest only"
}

test_hook_budget_then_warned_allow() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-budget")
  write_unverified_transcript "$dir/t.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 2 "$status" "first stop blocks"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 2 "$status" "second stop blocks"
  assert_contains "$out" 'Block 2 of 2' "second block must report the budget position"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 0 "$status" "the stop after the budget must be allowed"
  assert_contains "$out" '"systemMessage"' "the warned allow must speak to the captain through systemMessage"
  assert_contains "$out" "jira $JIRA_KEY" "the warning must name what stayed unverified"
  assert_absent "$dir/state/.livecheck-blocks" "the warned allow must reset the count"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 2 "$status" "after the reset the next unverified reply blocks again"
  assert_contains "$out" 'Block 1 of 2' "a new episode starts at one"
  printf 'session=s1\ncount=2\n' > "$dir/state/.livecheck-blocks"
  out=$(run_hook "$dir" "$(payload s2 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 2 "$status" "another session's count must not spend this session's budget"
  assert_contains "$out" 'Block 1 of 2' "a new session starts at one"
  out=$(FM_LIVECHECK_BLOCK_BUDGET=1 run_hook "$dir" "$(payload s3 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 2 "$status" "a budget of one blocks once"
  assert_contains "$out" 'Block 1 of 1' "the configured budget must be reported"
  out=$(FM_LIVECHECK_BLOCK_BUDGET=1 run_hook "$dir" "$(payload s3 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 0 "$status" "a budget of one allows on the second stop"
  pass "fm-livecheck-guard: bounded consecutive blocks per session, then a warned allow"
}

test_hook_ignores_stop_hook_active() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-sha")
  write_unverified_transcript "$dir/t.jsonl"
  out=$(printf '%s' "$(payload s1 "$dir/t.jsonl" "$MESSAGE")" | jq -c '.stop_hook_active = true' \
    | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1); status=$?
  expect_code 2 "$status" "stop_hook_active must not bypass the rule"
  pass "fm-livecheck-guard: stop_hook_active is not a bypass"
}

test_hook_bare_ref_guidance() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-ref")
  {
    t_prompt "ask"
    t_text "Captain, #7 is waiting on review."
  } > "$dir/t.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" 'Captain, #7 is waiting on review.')"); status=$?
  expect_code 2 "$status" "a bare ref is still a status claim"
  assert_contains "$out" 'ref #7' "the bare ref must be listed"
  assert_contains "$out" 'fm-verify-items.sh --repo <owner/repo> #7' "the banner must show how to bind the bare ref"
  assert_not_contains "$out" "fm-verify-items.sh '#7'" "a bare ref cannot be passed to the helper unbound"
  pass "fm-livecheck-guard: a bare #n blocks with repository guidance"
}

test_hook_falls_back_to_transcript_final_message() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fallback")
  write_unverified_transcript "$dir/t.jsonl"
  out=$(jq -n -c --arg t "$dir/t.jsonl" '{session_id:"s1", transcript_path:$t}' \
    | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1); status=$?
  expect_code 2 "$status" "without last_assistant_message the transcript's final text must be judged"
  assert_contains "$out" "jira $JIRA_KEY" "the fallback must read the transcript's final message"
  write_verified_transcript "$dir/t.jsonl"
  out=$(jq -n -c --arg t "$dir/t.jsonl" '{session_id:"s1", transcript_path:$t}' \
    | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1); status=$?
  expect_code 0 "$status" "the fallback must allow a verified reply"
  pass "fm-livecheck-guard: falls back to the transcript's trailing assistant text"
}

test_hook_unreadable_transcript_warns_and_allows() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-notranscript")
  out=$(run_hook "$dir" "$(payload s1 "$dir/missing.jsonl" "$MESSAGE")"); status=$?
  expect_code 0 "$status" "an unreadable transcript cannot be judged and must not wedge the session"
  assert_contains "$out" '"systemMessage"' "the captain must be told the items were not confirmed"
  assert_contains "$out" "pr $PR_URL" "the warning must name the unconfirmed items"
  out=$(jq -n -c --arg m "$MESSAGE" '{session_id:"s1", last_assistant_message:$m}' \
    | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1); status=$?
  expect_code 0 "$status" "a payload without transcript_path cannot be judged"
  assert_contains "$out" '"systemMessage"' "a missing transcript path must still warn"
  pass "fm-livecheck-guard: an unreadable transcript allows the stop with a warning"
}

test_hook_stands_down_outside_scope() {
  local base dir out status fake path_sans
  base="$TMP_ROOT/scope-base"
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/scope-crew")
  write_unverified_transcript "$dir/t.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 0 "$status" "a crewmate worktree must never be guarded"
  [ -z "$out" ] || fail "crewmate worktree produced output: $out"

  dir=$(make_primary_dir "$TMP_ROOT/scope-secondmate")
  printf 'sm-1\n' > "$dir/.fm-secondmate-home"
  write_unverified_transcript "$dir/t.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 2 "$status" "a marked secondmate home is a guarded primary"

  dir=$(make_primary_dir "$TMP_ROOT/scope-cursor")
  write_unverified_transcript "$dir/t.jsonl"
  out=$(printf '%s' "$(payload s1 "$dir/t.jsonl" "$MESSAGE")" | jq -c '. + {cursor_version:"2026.08.11-e8db854"}' \
    | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1); status=$?
  expect_code 0 "$status" "a Cursor-delivered payload must stand down"
  [ -z "$out" ] || fail "Cursor payload produced output: $out"

  dir=$(make_primary_dir "$TMP_ROOT/scope-off")
  write_unverified_transcript "$dir/t.jsonl"
  : > "$dir/config/livecheck-off"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" "$MESSAGE")"); status=$?
  expect_code 0 "$status" "config/livecheck-off must opt the home out"
  [ -z "$out" ] || fail "opted-out home produced output: $out"

  dir=$(make_primary_dir "$TMP_ROOT/scope-nojq")
  write_unverified_transcript "$dir/t.jsonl"
  path_sans=$(fm_test_base_path_sans "$PATH" jq)
  out=$(printf '%s' "$(payload s1 "$dir/t.jsonl" "$MESSAGE")" | PATH="$path_sans" FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --claude 2>&1); status=$?
  expect_code 0 "$status" "without jq the hook cannot read its payload and must allow"
  [ -z "$out" ] || fail "missing-jq run produced output: $out"

  dir=$(make_primary_dir "$TMP_ROOT/scope-mode")
  out=$(printf '{}' | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "the hook refuses to run without --claude"
  assert_contains "$out" 'usage' "the refusal must print usage"
  fake=$(printf '{}' | FM_HOME="$dir" bash "$dir/bin/fm-livecheck-guard.sh" --codex 2>&1); status=$?
  expect_code 2 "$status" "the hook refuses an unsupported harness flag"
  assert_contains "$fake" 'usage' "the unsupported-flag refusal must print usage"
  pass "fm-livecheck-guard: inert outside a primary home, under Cursor, when opted out, or without jq; refuses other harnesses"
}

test_hook_quoted_title_and_failed_lookup_end_the_turn() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-tep22")
  {
    t_prompt "what did the trends service design say"
    t_bash q1 "grep -ril trends data/"
    t_result q1 "data/notes.md"
    t_text 'Captain, the 2015 Confluence page "TEP-22: Trends Service" describes the design.'
  } > "$dir/t.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" 'Captain, the 2015 Confluence page "TEP-22: Trends Service" describes the design.')"); status=$?
  expect_code 0 "$status" "a key that only appears inside a quoted page title must end the turn without a lookup"
  [ -z "$out" ] || fail "quoted-title reply produced output: $out"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t.jsonl" 'Captain, TEP-22 describes the design.')"); status=$?
  expect_code 2 "$status" "the same key bare in prose with no lookup must still block"
  assert_contains "$out" "jira TEP-22" "banner must name the bare key"
  assert_contains "$out" "fm-verify-items.sh 'TEP-22'" "banner must give the verifier command"
  {
    t_prompt "what did the trends service design say"
    t_bash q2 "$dir/bin/fm-verify-items.sh 'TEP-22'"
    t_result q2 "jira	TEP-22	error	twg lookup failed (exit 1)" true
    t_text 'Captain, "TEP-22: Trends Service" is a 2015 page; there is no Jira issue TEP-22.'
  } > "$dir/t2.jsonl"
  out=$(run_hook "$dir" "$(payload s1 "$dir/t2.jsonl" 'Captain, "TEP-22: Trends Service" is a 2015 page; there is no Jira issue TEP-22.')"); status=$?
  expect_code 0 "$status" "a verifier run that answered error for the key is a live check, so the reply reporting that must end the turn"
  [ -z "$out" ] || fail "failed-lookup reply produced output: $out"
  assert_absent "$dir/state/.livecheck-blocks" "the allowed stop must reset the block count"
  pass "fm-livecheck-guard: the quoted-title reply and the failed-lookup reply end the turn, a bare unchecked key still blocks"
}

test_tracked_registration() {
  local entry
  entry=$(jq -r '.hooks.Stop[].hooks[] | select(.command | test("fm-livecheck-guard\\.sh")) | [.command, (.timeout // "none" | tostring)] | @tsv' "$ROOT/.claude/settings.json")
  [ -n "$entry" ] || fail "tracked .claude/settings.json must register the live-check guard as a Stop hook"
  # shellcheck disable=SC2016 # the literal marker guard is what the tracked entry must contain
  assert_contains "$entry" '[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0;' "the entry must carry the Grok marker guard"
  # shellcheck disable=SC2016 # the literal $CLAUDE_PROJECT_DIR is what the tracked entry must contain
  assert_contains "$entry" '"$CLAUDE_PROJECT_DIR"/bin/fm-livecheck-guard.sh --claude' "the entry must anchor through CLAUDE_PROJECT_DIR in --claude mode"
  [ "$(printf '%s' "$entry" | cut -f2)" != none ] || fail "the entry must declare a timeout"
  [ "$(jq -r '.hooks.Stop[].hooks[] | select(.command | test("fm-livecheck-guard\\.sh")) | .asyncRewake // false' "$ROOT/.claude/settings.json")" = false ] \
    || fail "the live-check guard must be synchronous: it decides the stop"
  pass ".claude/settings.json: the live-check guard is registered as a synchronous, Grok-guarded Stop hook"
}

test_extract_names_every_kind_once
test_extract_skips_fences_and_technical_tokens
test_extract_binds_bare_refs
test_extract_rejects_malformed_urls
test_extract_skips_quoted_titles_and_wiki_link_text
test_turn_records_start_after_newest_prompt
test_turn_records_treat_guard_feedback_as_continuation
test_turn_records_grow_the_tail_window
test_turn_records_unreadable_transcript_fails
test_final_message_is_trailing_assistant_text
test_verified_github_lookups
test_verified_jira_jenkins_gitlab_lookups
test_verified_helper_lines_and_compound_commands
test_hook_silent_without_items_or_payload
test_hook_blocks_unverified_with_banner_and_command
test_hook_allows_verified_and_resets_budget
test_hook_partial_verification_names_only_the_rest
test_hook_budget_then_warned_allow
test_hook_ignores_stop_hook_active
test_hook_bare_ref_guidance
test_hook_falls_back_to_transcript_final_message
test_hook_unreadable_transcript_warns_and_allows
test_hook_stands_down_outside_scope
test_hook_quoted_title_and_failed_lookup_end_the_turn
test_tracked_registration
