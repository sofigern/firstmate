#!/usr/bin/env bash
# fm-verify-items.sh - look up the live status of a batch of work items in one
# call and print one line per item, so a captain-facing reply can be answered
# from current state instead of from a ledger. This is the one command the
# live-status Stop hook (bin/fm-livecheck-guard.sh, docs/livecheck-guard.md)
# names; its output is what that hook recognizes as a live check.
#
# Usage:
#   fm-verify-items.sh [--repo <owner/repo>] [--timeout <seconds>] <item>...
#   fm-verify-items.sh [--repo <owner/repo>] [--timeout <seconds>] -   (items on stdin)
#
# Items are anything bin/fm-livecheck-lib.sh's fm_livecheck_extract_items
# recognizes, in any spelling that extractor accepts: GitHub pull request and
# issue URLs, GitLab merge request URLs, Jira keys or /browse/ URLs, Jenkins
# build URLs, explicit <owner>/<repo>#<n> references (the form the guard banner
# prints), and bare #<n> references, which --repo (or a single GitHub URL
# among the items) binds to a repository. Duplicates collapse.
#
# Output, one TAB-separated line per item, in canonical item order:
#   <kind>\t<id>\t<state>\t<detail>
#   pr       open | draft | merged | closed      detail: merged_at=<ts> closed_at=<ts> checks=pass|fail|pending|none review=<decision> mergeable=<status> title="..."
#            (a GitLab merge request reports opened | merged | closed | locked with title only)
#   issue    open | closed                       detail: reason=<stateReason> closed_at=<ts> title="..."
#   ref      the pull request's line when the number is a pull request, else the issue's
#   jira     todo | in-progress | done           detail: status="<name>" resolution=<name|none> updated=<ts> summary="..."
#            (the state is the Jira status category: new, indeterminate, done)
#   jenkins  building | success | failure | unstable | aborted | not_built   detail: started=<iso> duration_s=<n> url=<url>
#   any      error        <what failed>          the lookup ran and failed (auth, network, not found)
#   any      unverified   <what is missing>      no backend can check this item here
# Exit status is 0 when every item got a real state, 1 when any item is
# error or unverified, 2 on usage errors. Nothing it prints is a credential.
#
# Backends and credentials, read fresh on every run:
#   GitHub   gh (authenticated as usual: `gh auth status`)
#   GitLab   glab (its own authentication); the instance comes from the URL
#   Jira     REST when FM_JIRA_BASE_URL, FM_JIRA_EMAIL, and FM_JIRA_TOKEN are
#            set (Jira Cloud basic auth with an API token), else the Atlassian
#            `twg` CLI when installed, else unverified
#   Jenkins  curl against <build>/api/json; FM_JENKINS_AUTH ("user:token") or
#            FM_JENKINS_AUTH_FILE (a file holding "user:token") adds basic auth
#            for instances that need it, else the request is anonymous
# Those variables come from the environment or from config/livecheck.env in
# the effective FM_HOME, sourced if present (docs/configuration.md "Live-status
# check credentials"). Each lookup is hard-bounded to --timeout seconds
# (default 20, bin/fm-timeout-lib.sh); a bound hit is an error line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-livecheck-lib.sh
. "$SCRIPT_DIR/fm-livecheck-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

REPO=
TIMEOUT=20
TEXT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { echo "fm-verify-items.sh: --repo needs <owner/repo>" >&2; exit 2; }
      REPO=$2
      shift 2
      ;;
    --repo=*) REPO=${1#--repo=}; shift ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "fm-verify-items.sh: --timeout needs <seconds>" >&2; exit 2; }
      TIMEOUT=$2
      shift 2
      ;;
    --timeout=*) TIMEOUT=${1#--timeout=}; shift ;;
    -h|--help) usage; exit 0 ;;
    -) TEXT="$TEXT $(cat)"; shift ;;
    --) shift; while [ "$#" -gt 0 ]; do TEXT="$TEXT $1"; shift; done ;;
    -*) echo "fm-verify-items.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) TEXT="$TEXT $1"; shift ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*|0) echo "fm-verify-items.sh: --timeout must be a positive integer" >&2; exit 2 ;; esac
if [ -n "$REPO" ]; then
  case "$REPO" in
    */*) ;;
    *) echo "fm-verify-items.sh: --repo must be <owner/repo>" >&2; exit 2 ;;
  esac
fi

if [ -f "$CONFIG/livecheck.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$CONFIG/livecheck.env"
  set +a
fi

ITEMS=$(fm_livecheck_extract_items "$TEXT" "$REPO")
if [ -z "$ITEMS" ]; then
  echo "fm-verify-items.sh: no recognizable work item among the arguments" >&2
  exit 2
fi

FAILED=0
emit() {  # <kind> <id> <state> <detail>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
  case "$3" in error|unverified) FAILED=1 ;; esac
}

json_str() {  # <string> -> a JSON string with quotes trimmed to one line
  printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-120
}

run() {  # <command...> -> stdout captured, 124 on timeout
  fm_run_timed "$TIMEOUT" "$@" 2>/dev/null
}

github_pr() {  # <url-or-number> [--repo owner/repo] -> prints "state<TAB>detail" or returns 1
  local raw
  raw=$(run gh pr view "$@" --json state,isDraft,mergedAt,closedAt,mergeStateStatus,reviewDecision,statusCheckRollup,title,url) || return 1
  printf '%s' "$raw" | jq -r '
    def checks:
      (.statusCheckRollup // []) as $c
      | if ($c | length) == 0 then "none"
        elif any($c[]; (.conclusion // .state // "") | test("^(FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE)$")) then "fail"
        elif any($c[]; (.conclusion // .state // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$") | not) then "pending"
        else "pass" end;
    (if .state == "MERGED" then "merged"
     elif .state == "CLOSED" then "closed"
     elif .isDraft == true then "draft" else "open" end) as $state
    | [$state,
       ("merged_at=" + (.mergedAt // "-") + " closed_at=" + (.closedAt // "-")
        + " checks=" + checks + " review=" + (.reviewDecision // "-" | if . == "" then "-" else . end)
        + " mergeable=" + (.mergeStateStatus // "-") + " title=\"" + ((.title // "") | gsub("[\n\t]"; " ")) + "\" url=" + (.url // "-"))]
    | @tsv' 2>/dev/null
}

github_issue() {  # <url-or-number> [--repo owner/repo]
  local raw
  raw=$(run gh issue view "$@" --json state,stateReason,closedAt,title,url) || return 1
  printf '%s' "$raw" | jq -r '
    [(.state | ascii_downcase),
     ("reason=" + (.stateReason // "-" | if . == "" then "-" else . end) + " closed_at=" + (.closedAt // "-")
      + " title=\"" + ((.title // "") | gsub("[\n\t]"; " ")) + "\" url=" + (.url // "-"))]
    | @tsv' 2>/dev/null
}

gitlab_mr() {  # <number> <host> <path>
  local raw state title
  command -v glab >/dev/null 2>&1 || { printf 'unverified\tglab is not installed\n'; return 0; }
  raw=$(run glab mr view "$1" -R "https://$2/$3") || return 1
  state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1)
  [ -n "$state" ] || return 1
  title=$(printf '%s\n' "$raw" | sed -n 's/^title:[[:space:]]*//p' | head -1)
  printf '%s\ttitle="%s"\n' "$state" "$(json_str "$title")"
}

jira_summarize() {  # stdin: REST issue JSON or twg JSON -> "state<TAB>detail"
  jq -r '
    (if type == "object" and has("data") then (.data | if type == "array" then .[0] else . end) else . end) as $i
    | ($i.fields // $i) as $f
    | ($f.status.statusCategory.key // "") as $cat
    | (if $cat == "done" then "done" elif $cat == "new" then "todo"
       elif $cat == "indeterminate" then "in-progress" else "error" end) as $state
    | if ($f.status.name // "") == "" then "error\tno status in the Jira response"
      else [$state,
            ("status=\"" + ($f.status.name // "") + "\" resolution=" + ($f.resolution.name // "none")
             + " updated=" + ($f.updated // "-") + " summary=\"" + (($f.summary // "") | gsub("[\n\t]"; " ")) + "\"")]
           | @tsv end' 2>/dev/null
}

jira_issue() {  # <KEY>
  local raw code
  if [ -n "${FM_JIRA_BASE_URL:-}" ] && [ -n "${FM_JIRA_EMAIL:-}" ] && [ -n "${FM_JIRA_TOKEN:-}" ]; then
    raw=$(run curl -sS -f -u "$FM_JIRA_EMAIL:$FM_JIRA_TOKEN" -H 'Accept: application/json' \
      "${FM_JIRA_BASE_URL%/}/rest/api/3/issue/$1?fields=status,resolution,summary,updated"); code=$?
    [ "$code" -eq 0 ] || { printf 'error\tjira rest lookup failed (curl exit %s)\n' "$code"; return 0; }
    printf '%s' "$raw" | jira_summarize
    return 0
  fi
  if command -v twg >/dev/null 2>&1; then
    raw=$(run twg jira workitem get "$1" --output json --output-summary none); code=$?
    [ "$code" -eq 0 ] || { printf 'error\ttwg lookup failed (exit %s)\n' "$code"; return 0; }
    printf '%s' "$raw" | jira_summarize
    return 0
  fi
  printf 'unverified\tno Jira backend: set FM_JIRA_BASE_URL, FM_JIRA_EMAIL, and FM_JIRA_TOKEN in config/livecheck.env, or install twg\n'
}

jenkins_build() {  # <build-url>
  local raw code auth=
  if [ -n "${FM_JENKINS_AUTH:-}" ]; then
    auth=$FM_JENKINS_AUTH
  elif [ -n "${FM_JENKINS_AUTH_FILE:-}" ] && [ -r "$FM_JENKINS_AUTH_FILE" ]; then
    auth=$(head -1 "$FM_JENKINS_AUTH_FILE")
  fi
  if [ -n "$auth" ]; then
    raw=$(run curl -sS -f -u "$auth" "$1/api/json?tree=building,result,number,timestamp,duration,url"); code=$?
  else
    raw=$(run curl -sS -f "$1/api/json?tree=building,result,number,timestamp,duration,url"); code=$?
  fi
  [ "$code" -eq 0 ] || { printf 'error\tjenkins lookup failed (curl exit %s)\n' "$code"; return 0; }
  printf '%s' "$raw" | jq -r '
    (if .building == true then "building"
     elif (.result // "") == "" then "error"
     else (.result | ascii_downcase) end) as $state
    | [$state,
       ("started=" + (if .timestamp then ((.timestamp / 1000) | floor | todate) else "-" end)
        + " duration_s=" + (if .duration then ((.duration / 1000) | floor | tostring) else "-" end)
        + " url=" + (.url // "-"))]
    | @tsv' 2>/dev/null
}

while IFS=$'\t' read -r kind id; do
  [ -n "$id" ] || continue
  line=
  case "$kind" in
    pr)
      if fm_pr_url_parse "$id" && [ "$FM_PR_PROVIDER" = gitlab ]; then
        line=$(gitlab_mr "$FM_PR_NUMBER" "$FM_PR_HOST" "$FM_PR_PATH") || line=
      else
        line=$(github_pr "$id") || line=
      fi
      [ -n "$line" ] || line=$(printf 'error\tgh pr view failed (not found, no access, or gh not authenticated)')
      ;;
    issue)
      line=$(github_issue "$id") || line=
      [ -n "$line" ] || line=$(printf 'error\tgh issue view failed (not found, no access, or gh not authenticated)')
      ;;
    ref)
      case "$id" in
        '#'*)
          line=$(printf 'unverified\tbare %s names no repository: pass --repo <owner/repo> or the full URL' "$id")
          ;;
        *)
          repo=${id%%#*}
          number=${id##*#}
          line=$(github_pr "$number" --repo "$repo") || line=
          [ -n "$line" ] || line=$(github_issue "$number" --repo "$repo") || line=
          [ -n "$line" ] || line=$(printf 'error\tneither a pull request nor an issue %s was readable in %s' "$number" "$repo")
          ;;
      esac
      ;;
    jira)
      line=$(jira_issue "$id")
      [ -n "$line" ] || line=$(printf 'error\tjira response could not be read')
      ;;
    jenkins)
      line=$(jenkins_build "$id")
      [ -n "$line" ] || line=$(printf 'error\tjenkins response could not be read')
      ;;
    *) line=$(printf 'unverified\tunknown item kind') ;;
  esac
  state=${line%%	*}
  detail=${line#*	}
  [ "$detail" != "$line" ] || detail=
  emit "$kind" "$id" "$state" "$detail"
done <<EOF
$ITEMS
EOF

exit "$FAILED"
