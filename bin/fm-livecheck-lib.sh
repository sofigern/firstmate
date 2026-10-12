#!/usr/bin/env bash
# fm-livecheck-lib.sh - the single owner of the live-status rule's mechanics:
# which work items a captain-facing reply names, which calls in the current
# turn count as a live status check of each one, and the canonical item
# spelling that bin/fm-livecheck-guard.sh, bin/fm-verify-items.sh, and the
# tests all agree on. docs/livecheck-guard.md owns the rule itself and its
# rationale; this header owns the exact formats.
#
# Sourced, never executed. No side effects on source.
#
# Canonical item lines are TAB-separated "<kind>\t<id>":
#   pr       https://github.com/<owner>/<repo>/pull/<n>
#            https://<gitlab-host>/<path>/-/merge_requests/<n>
#   issue    https://github.com/<owner>/<repo>/issues/<n>
#   ref      <owner>/<repo>#<n>  a bare #<n> resolved against the reply's only
#                                GitHub repository (or the caller's --repo)
#            #<n>                a bare #<n> with no single repository to bind to
#   jira     <KEY-123>
#   jenkins  https://<host>[/view/<v>]/job/<a>[/job/<b>...]/<n>  (no trailing /)
#
# fm_livecheck_extract_items <text> [default-repo]
#     Print the canonical item lines <text> names, deduplicated, URLs and keys
#     in first-mention order with bare refs last. Fenced code blocks
#     (``` or ~~~) are skipped: a fence is where a reply shows a draft, a
#     command, or quoted text verbatim, so an item inside one is not the
#     reply's own status claim. Inline code spans are NOT skipped. Trailing
#     punctuation and markdown emphasis around a token are ignored. A Jira key
#     is two or more capitals, optional capitals or digits, a dash, and one to
#     six digits, standing alone or under /browse/ in a URL; well-known
#     technical tokens of that shape (UTF-8, SHA-256, ISO-8601, CVE-..., ...)
#     are excluded by FM_LIVECHECK_JIRA_IGNORE below.
#
# fm_livecheck_turn_records <transcript-path>
#     Print one JSON object per tool call in the current turn, joined with its
#     result: {"name":..,"input":<json string>,"result":<text>,"error":<bool>}.
#     The turn starts after the newest captain prompt. A user entry is a prompt
#     when it is not meta and carries plain text rather than tool results. A
#     Stop-hook feedback message whose body carries this guard's own banner
#     marker (FM_LIVECHECK) or the supervision guard's banner (TURN WOULD END
#     BLIND) is a continuation of the same turn, not a boundary, so a check
#     made before such a block still counts for the reply sent after it; every
#     other prompt, including a watcher rewake, starts a new turn. Sidechain
#     (subagent) entries are ignored. The transcript is read in growing tails
#     (1 MiB, then x4 up to FM_LIVECHECK_MAX_WINDOW bytes, default 64 MiB), so
#     a multi-hundred-megabyte transcript costs only its last turn; a tail that
#     reaches the cap with no prompt in it is used as the turn. Unparsable
#     lines are skipped. Returns 1 when the transcript cannot be read at all.
#
# fm_livecheck_final_message <transcript-path>
#     Print the current turn's trailing assistant text: every text block after
#     the turn's last tool result. The fallback for a hook payload that carries
#     no last_assistant_message.
#
# fm_livecheck_verified <items-file> <records-file>
#     Print the subset of canonical item lines in <items-file> that a
#     recognized live lookup among <records-file>'s turn records names. A
#     lookup is recognized by what it is, not by what it printed:
#       verifier  a Bash command running fm-verify-items.sh; only its result
#                 lines whose state is not error/unverified count, matched on
#                 the exact canonical "<kind>\t<id>\t" prefix
#       github    gh or gh-axi "pr|issue view|checks|status|list", or a
#                 read-only gh api call on a /pulls/ or /issues/ path (no -X,
#                 --method, -f, -F, --field, --raw-field, or --input), or a
#                 GitHub MCP read tool (get_pull_request, get_issue, ...)
#       jira      twg jira workitem get|query|search, or an MCP getJiraIssue,
#                 searchJiraIssuesUsingJql, or Atlassian fetch tool
#       jenkins   a command reading <build>/api/json, or tb-jenkins info|status
#       gitlab    glab mr view
#     A record whose result is an error never counts. Within a recognized
#     record the item must appear in its input or result: the full URL, its
#     repository pull/pulls/issues path with the number, a view/checks/status
#     command naming the number (and the same --repo when one is given), the
#     Jira key as a whole word, or the Jenkins build URL (trailing slash
#     tolerated) or "info <job> <n>". Reading a ledger, backlog, or status file
#     that happens to contain the identifier is not a lookup and never counts.

FM_LIVECHECK_JIRA_IGNORE=${FM_LIVECHECK_JIRA_IGNORE:-UTF SHA RFC ISO CVE MD5 GPT COVID HTTP HTTPS SSL TLS ECMA IEEE PEP AES RSA UUID IPV IEC ANSI ASCII CRC HMAC PBKDF ED25519 SSH FIPS DNS OAUTH}
FM_LIVECHECK_MAX_WINDOW=${FM_LIVECHECK_MAX_WINDOW:-67108864}
case "$FM_LIVECHECK_MAX_WINDOW" in ''|*[!0-9]*|0) FM_LIVECHECK_MAX_WINDOW=67108864 ;; esac

# shellcheck source=bin/fm-pr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"

fm_livecheck_jira_ignored() {  # <prefix>
  local prefix=$1 word
  for word in $FM_LIVECHECK_JIRA_IGNORE; do
    [ "$word" = "$prefix" ] && return 0
  done
  return 1
}

# Print one token per line from the prose outside fenced blocks. Tokens keep
# the characters a URL, key, or #ref needs and drop everything else.
fm_livecheck_tokens() {  # <text>
  local LC_ALL=C
  printf '%s\n' "$1" \
    | awk 'BEGIN { fence = 0 }
           /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
           !fence { print }' \
    | tr -c 'A-Za-z0-9_./:#?=&%+-\n' '\n' \
    | sed -e 's/[.,;:!?]*$//' -e '/^$/d'
}

fm_livecheck_extract_items() {  # <text> [default-repo]
  local text=${1-} default_repo=${2-} token seen=$'\n' refs=$'\n' repos=$'\n' repo_count=0 \
    url kind id number trailer LC_ALL=C
  local pr_pat='^(https?://github\.com/[^/]+/[^/]+/pull/[1-9][0-9]*)(/.*|#.*|\?.*)?$'
  local issue_pat='^https?://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100})/issues/([1-9][0-9]*)(/.*|#.*|\?.*)?$'
  local mr_pat='^(https?://[^/]+/.+/-/merge_requests/[1-9][0-9]*)(/.*|#.*|\?.*)?$'
  local browse_pat='^https?://[^/]+/browse/([A-Z][A-Z0-9]+-[0-9]+)(/.*|#.*|\?.*)?$'
  local jenkins_pat='^(https?://[A-Za-z0-9.-]+(:[0-9]+)?(/view/[A-Za-z0-9._%-]+)?)((/job/[A-Za-z0-9._%-]+)+)/([1-9][0-9]*)(/.*|#.*|\?.*)?$'
  local jira_pat='^([A-Z]{2,}[A-Z0-9]*)-([0-9]{1,6})$'
  local ref_pat='^#([1-9][0-9]*)$'
  emit() {  # <kind> <id>
    case "$seen" in *$'\n'"$1	$2"$'\n'*) return 0 ;; esac
    seen+="$1	$2"$'\n'
    printf '%s\t%s\n' "$1" "$2"
  }
  note_repo() {  # <owner/repo>
    case "$repos" in *$'\n'"$1"$'\n'*) return 0 ;; esac
    repos+="$1"$'\n'
    repo_count=$((repo_count + 1))
  }
  while IFS= read -r token; do
    token=${token#"${token%%[!*_~]*}"}
    token=${token%"${token##*[!*_~]}"}
    [ -n "$token" ] || continue
    if [[ "$token" =~ $pr_pat ]]; then
      url=${BASH_REMATCH[1]}
      url=${url/http:\/\//https://}
      if fm_pr_url_parse "$url"; then
        note_repo "$FM_PR_PATH"
        emit pr "$FM_PR_URL"
      fi
      continue
    fi
    if [[ "$token" =~ $issue_pat ]]; then
      note_repo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
      emit issue "https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/issues/${BASH_REMATCH[3]}"
      continue
    fi
    if [[ "$token" =~ $mr_pat ]]; then
      url=${BASH_REMATCH[1]}
      url=${url/http:\/\//https://}
      fm_pr_url_parse "$url" && emit pr "$FM_PR_URL"
      continue
    fi
    if [[ "$token" =~ $browse_pat ]]; then
      id=${BASH_REMATCH[1]}
      if [[ "$id" =~ $jira_pat ]] && ! fm_livecheck_jira_ignored "${BASH_REMATCH[1]}"; then
        emit jira "$id"
      fi
      continue
    fi
    if [[ "$token" =~ $jenkins_pat ]]; then
      url="${BASH_REMATCH[1]}${BASH_REMATCH[4]}/${BASH_REMATCH[6]}"
      emit jenkins "$url"
      continue
    fi
    case "$token" in
      *://*) continue ;;
    esac
    if [[ "$token" =~ $jira_pat ]]; then
      fm_livecheck_jira_ignored "${BASH_REMATCH[1]}" || emit jira "$token"
      continue
    fi
    if [[ "$token" =~ $ref_pat ]]; then
      number=${BASH_REMATCH[1]}
      case "$refs" in *$'\n'"$number"$'\n'*) continue ;; esac
      refs+="$number"$'\n'
    fi
  done < <(fm_livecheck_tokens "$text")
  [ "$refs" != $'\n' ] || return 0
  if [ -n "$default_repo" ]; then
    kind=$default_repo
  elif [ "$repo_count" -eq 1 ]; then
    kind=${repos#$'\n'}
    kind=${kind%$'\n'}
  else
    kind=
  fi
  trailer=${refs#$'\n'}
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    if [ -n "$kind" ]; then
      emit ref "$kind#$number"
    else
      emit ref "#$number"
    fi
  done <<EOF
$trailer
EOF
}

# jq program shared by the turn readers: slurps raw transcript lines, keeps the
# parsable user/assistant main-chain entries, finds the newest prompt that is
# not a guard continuation, and exposes the entries after it as $turn.
# shellcheck disable=SC2016 # the $ names below are jq variables, not shell
FM_LIVECHECK_JQ_PRELUDE='
  def entries:
    split("\n") | map(select(length > 0) | (fromjson? // empty))
    | map(select(type == "object" and (.type == "user" or .type == "assistant")
                 and .isSidechain != true and (.message | type) == "object"));
  def prompt_text:
    if (.message.content | type) == "string" then .message.content
    else ([.message.content[]? | select(.type == "text") | .text] | join("\n")) end;
  def is_prompt:
    .type == "user" and .isMeta != true
    and ((.message.content | type) == "string"
         or ((.message.content | type) == "array"
             and any(.message.content[]?; .type == "text")
             and all(.message.content[]?; .type != "tool_result")));
  def is_continuation:
    (prompt_text | test("Stop hook feedback"))
    and (prompt_text | test("FM_LIVECHECK|TURN WOULD END BLIND"));
  def boundary:
    [to_entries[] | select(.value | is_prompt and (is_continuation | not)) | .key] | max;
  def turn_of($all):
    ($all | boundary) as $b
    | if $b == null then {found: false, turn: $all}
      else {found: true, turn: $all[($b + 1):]} end;
'

# shellcheck disable=SC2016 # the $ names below are jq variables, not shell
FM_LIVECHECK_JQ_RECORDS="$FM_LIVECHECK_JQ_PRELUDE"'
  def result_text:
    if (.content | type) == "string" then .content
    elif (.content | type) == "array" then ([.content[]? | select(.type == "text") | .text] | join("\n"))
    else "" end;
  turn_of(entries) as $t
  | ($t.turn | map(select(.type == "user")
      | .message.content | if type == "array" then .[] else empty end
      | select(.type == "tool_result")
      | {key: .tool_use_id, value: {result: result_text, error: (.is_error == true)}})
     | from_entries) as $results
  | {found: $t.found},
    ($t.turn[] | select(.type == "assistant")
      | .message.content | if type == "array" then .[] else empty end
      | select(.type == "tool_use")
      | {name: .name, input: (.input | tojson),
         result: ($results[.id].result // ""), error: ($results[.id].error // false)})
'

# shellcheck disable=SC2016 # the $ names below are jq variables, not shell
FM_LIVECHECK_JQ_FINAL="$FM_LIVECHECK_JQ_PRELUDE"'
  turn_of(entries) as $t
  | ($t.turn | [to_entries[] | select(.value.type == "user") | .key] | max) as $last_user
  | {found: $t.found},
    ($t.turn | if $last_user == null then . else .[($last_user + 1):] end
     | [.[] | select(.type == "assistant") | .message.content
         | if type == "array" then .[] else empty end
         | select(.type == "text") | .text]
     | join("\n"))
'

# Run <jq-program> over the current turn of <transcript>, printing its output
# minus the leading {found} record when <strip-found> is 1.
fm_livecheck_turn_run() {  # <transcript> <jq-program> <strip-found>
  local transcript=$1 program=$2 strip=$3 size window=1048576 tmp out found
  [ -f "$transcript" ] && [ -r "$transcript" ] || return 1
  size=$(wc -c < "$transcript" 2>/dev/null | tr -d ' ') || return 1
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-livecheck.XXXXXX") || return 1
  while :; do
    if [ "$window" -ge "$size" ]; then
      cat "$transcript" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
      found=complete
    else
      tail -c "$window" "$transcript" 2>/dev/null | sed '1d' > "$tmp" || { rm -f "$tmp"; return 1; }
      found=
    fi
    out=$(jq -R -s -c "$program" "$tmp" 2>/dev/null) || { rm -f "$tmp"; return 1; }
    [ "$found" = complete ] || found=$(printf '%s\n' "$out" | head -1 | jq -r '.found // false' 2>/dev/null)
    if [ "$found" = complete ] || [ "$found" = true ] || [ "$window" -ge "$FM_LIVECHECK_MAX_WINDOW" ]; then
      rm -f "$tmp"
      if [ "$strip" -eq 1 ]; then
        printf '%s\n' "$out" | sed '1d'
      else
        printf '%s\n' "$out"
      fi
      return 0
    fi
    window=$((window * 4))
  done
}

fm_livecheck_turn_records() {  # <transcript-path>
  fm_livecheck_turn_run "$1" "$FM_LIVECHECK_JQ_RECORDS" 1
}

fm_livecheck_final_message() {  # <transcript-path>
  local out
  out=$(fm_livecheck_turn_run "$1" "$FM_LIVECHECK_JQ_FINAL" 1) || return 1
  printf '%s' "$out" | jq -r '.' 2>/dev/null
}

# shellcheck disable=SC2016 # the $ names below are jq variables, not shell
FM_LIVECHECK_JQ_VERIFIED='
  def rx_escape: gsub("(?<c>[.\\\\+*?\\[^\\]$(){}=!<>|:\\-#/])"; "\\\(.c)");
  def command: (.input | fromjson? // {} | .command // "");
  def kinds_of:
    if .name == "Bash" then
      command as $c
      | [ (if ($c | test("fm-verify-items\\.sh")) then "verifier" else empty end),
          (if ($c | test("(^|[^A-Za-z0-9_./-])gh(-axi)?[[:space:]]+(pr|issue)[[:space:]]+(view|checks|status|list)([[:space:]]|$)"))
              or (($c | test("(^|[^A-Za-z0-9_./-])gh(-axi)?[[:space:]]+api([[:space:]]|$)"))
                  and ($c | test("/(pulls|issues)/[0-9]+"))
                  and (($c | test("(^|[[:space:]])(-X|--method|-f|-F|--field|--raw-field|--input)([[:space:]=]|$)")) | not))
           then "github" else empty end),
          (if ($c | test("(^|[^A-Za-z0-9_./-])glab[[:space:]]+mr[[:space:]]+view([[:space:]]|$)")) then "gitlab" else empty end),
          (if ($c | test("(^|[^A-Za-z0-9_./-])twg[[:space:]]+jira[[:space:]]+workitem[[:space:]]+(get|query|search)([[:space:]]|$)")) then "jira" else empty end),
          (if ($c | test("(^|[^A-Za-z0-9_./-])tb-jenkins[[:space:]]+((-c|--cluster)[[:space:]]+[^[:space:]]+[[:space:]]+)?(info|status)([[:space:]]|$)"))
              or ($c | test("/api/json")) then "jenkins" else empty end) ]
    elif (.name | test("getJiraIssue$|searchJiraIssuesUsingJql$|__fetch$")) then ["jira"]
    elif (.name | test("get_pull_request|get_issue|pull_request_read|issue_read|list_pull_requests")) then ["github"]
    else [] end;
  def hay: (.input + "\n" + .result);
  def good_verifier_lines:
    [.result | split("\n")[] | select(test("^(pr|issue|ref|jira|jenkins)\t[^\t]+\t(error|unverified)(\t|$)") | not)];
  def repo_ok($repo):
    command as $c
    | ($c | capture("(^|[[:space:]])(--repo|-R)[[:space:]=]+(?<r>[^[:space:];&|]+)") | .r // null) as $given
    | $given == null or $repo == null or $given == $repo or $given == ("https://github.com/" + $repo);
  def pr_number: (.id | capture("/(pull|merge_requests)/(?<n>[0-9]+)$") | .n);
  def names($item):
    ($item.kind) as $k | ($item.id) as $id
    | if $k == "jira" then
        (hay | test("(^|[^A-Za-z0-9-])" + ($id | rx_escape) + "([^0-9-]|$)"))
      elif $k == "jenkins" then
        (hay | test(($id | rx_escape) + "/?([^0-9/]|$)"))
        or (($id | capture("/job/(?<job>[^/]+)/(?<n>[0-9]+)$")) as $j
            | command | test("(info|status)[[:space:]]+" + ($j.job | rx_escape) + "[[:space:]]+" + $j.n + "([^0-9]|$)"))
      elif $k == "pr" and ($id | test("/-/merge_requests/")) then
        ($id | capture("/(?<n>[0-9]+)$") | .n) as $n
        | (hay | test(($id | rx_escape) + "([^0-9]|$)"))
          or (hay | test("merge_requests/" + $n + "([^0-9]|$)"))
          or (command | test("mr[[:space:]]+view[[:space:]]+" + $n + "([^0-9]|$)"))
      else
        ($id | capture("^(https://github\\.com/)?(?<repo>[^#/]+/[^#/]+)?(/(pull|issues)/|#)(?<n>[0-9]+)$")) as $m
        | ($m.repo) as $repo | ($m.n) as $n
        | (if $repo == null then "" else ($repo | rx_escape) + "/" end) as $rp
        | (hay | test($rp + "(pull|pulls|issues)/" + $n + "([^0-9]|$)"))
          or ((command | test("(pr|issue)[[:space:]]+(view|checks|status)[[:space:]]+(-[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)*" + $n + "([^0-9]|$)")) and repo_ok($repo))
      end;
  def accepts($item):
    kinds_of as $kinds
    | if ($kinds | length) == 0 or .error then false
      elif ($kinds | index("verifier")) != null
           and (good_verifier_lines | any(startswith($item.kind + "\t" + $item.id + "\t"))) then true
      elif ($item.kind == "jira" and ($kinds | index("jira")) != null)
           or ($item.kind == "jenkins" and ($kinds | index("jenkins")) != null)
           or (($item.kind == "pr" or $item.kind == "issue" or $item.kind == "ref")
               and (($kinds | index("github")) != null or ($kinds | index("gitlab")) != null)) then
        names($item)
      else false end;
  ($items | split("\n") | map(select(length > 0) | split("\t") | {kind: .[0], id: .[1]})) as $wanted
  | ($records | split("\n") | map(select(length > 0) | (fromjson? // empty))) as $recs
  | $wanted[] | select(. as $item | any($recs[]; accepts($item))) | "\(.kind)\t\(.id)"
'

fm_livecheck_verified() {  # <items-file> <records-file>
  jq -n -r --rawfile items "$1" --rawfile records "$2" "$FM_LIVECHECK_JQ_VERIFIED"
}
