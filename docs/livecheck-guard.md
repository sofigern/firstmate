# Live-status guard

This is the authoritative current contract for the rule that a captain-facing reply may not name a work item whose live status that turn never looked up.
The hook is `bin/fm-livecheck-guard.sh`, the item and lookup formats are owned by `bin/fm-livecheck-lib.sh`, and the one-call batch check is `bin/fm-verify-items.sh`; each header owns its exact mechanics.
`AGENTS.md` section 9 points here, and the rule lives in the mechanism, not in prose.

## Why it exists

Firstmate's replies list open work from ledgers, status lines, backlog notes, and memory.
Those are history, and items already merged, deployed, or closed were presented to the captain as open.
The captain asked for a step in the process that cannot be skipped, so the rule is enforced at the turn boundary by a Stop hook rather than remembered.

## The rule

When a Claude primary session is about to end a turn, the hook reads the reply the captain is about to see and extracts the work items it names.
For each item it looks for a live status lookup of that item earlier in the same turn.
If every item was looked up, the turn ends.
If any was not, the turn does not end: the hook names the unverified items and the one command that checks them all, and the reply is written again from the result.

### What counts as a work item

- A GitHub pull request URL or issue URL, in any spelling that carries the number (`/files`, a fragment, or a query string after it is ignored).
- A GitLab merge request URL on any instance.
- A Jira key: two or more capitals, optional capitals or digits, a dash, and one to six digits, standing alone or under `/browse/` in a URL.
  Well-known technical tokens of that shape (`UTF-8`, `SHA-256`, `CVE-2024-1234`, `ISO-8601`, `Q3-2026`) are not keys; the library header owns the exclusion list.
- A Jenkins build URL: a host, optionally a view, one or more `/job/<name>` segments, and a build number.
- An explicit `<owner>/<repo>#<n>`, taken as written; this is the form the banner's fix command prints for a bound reference.
- A bare `#<n>`, bound to the reply's only GitHub repository when exactly one appears in the reply, otherwise left bare.
  Section 9 of `AGENTS.md` already requires full URLs, so a bare number is the exception, and the banner says to give the URL or name the repository.

Three kinds of span are quoted text rather than the reply's own status claim, and an item inside one is exempt:

- A fenced code block, where a reply shows a draft, a command, or quoted text verbatim.
- A double-quoted span, straight `"..."` or curly `“...”`, that opens and closes on one line, where a reply names a page, document, or message by its title.
  An unbalanced quote exempts nothing.
- The bracketed text of a Markdown link whose target is a Confluence or wiki page, where the text is that page's title.
  A target is a Confluence or wiki page when its host contains `confluence` or `wiki` or its path starts with `/wiki/`, `/confluence/`, or `/display/`.
  The target itself is still read, so a link to a `/browse/` URL still names its key, and the text of a link to any other target is ordinary prose.

The exemption exists because a Confluence page titled `"TEP-22: Trends Service"` is not a claim about a Jira issue `TEP-22`, and the first version of this hook blocked that reply twice.
Inline code spans are not exempt, because a key in backticks is still a claim about that key.
A bare key or a key in ordinary prose is always a claim.

### What counts as a live check

A lookup is recognized by what it is, never by what it printed, so reading a ledger, backlog, or status file that happens to contain an identifier never counts.
Recognized lookups are:

- `bin/fm-verify-items.sh`, where every result line except an `unverified` one counts, matched on the exact canonical item: an `error` line means the lookup ran and failed, while `unverified` means no backend could look at all.
- `gh` or `gh-axi` `pr view`, `pr checks`, `pr status`, `pr list`, `issue view`, or a read-only `gh api` call on a `/pulls/` or `/issues/` path, and GitHub MCP read tools.
- `glab mr view` for a merge request.
- `twg jira workitem get`, `query`, or `search`, and the Atlassian MCP `getJiraIssue`, `searchJiraIssuesUsingJql`, and `fetch` tools.
- A command reading a build's `/api/json`, or `tb-jenkins info` or `status`.

Within a recognized call the item must appear in its input or its result: the full URL, the repository's `pull`, `pulls`, or `issues` path with the number, a `view`, `checks`, or `status` command naming the number under the same `--repo` when one is given, the Jira key as a whole word, or the Jenkins build URL.
A recognized call counts whatever it returned, including a not-found answer, an access error, or an outage: the rule is that firstmate looked live this turn, and the result, including "does not exist", is what the reply then reports.
Without that, a lookup of an item that is not a work item at all, such as a key that only ever named a document, could never satisfy the hook and only the budget below would end the turn.
One command that runs several lookups verifies every item it names.

### Where the turn starts

The turn starts after the newest captain prompt in the transcript.
A Stop-hook feedback message carrying this hook's own banner, or the supervision guard's banner from `bin/fm-turnend-guard.sh`, is a continuation of the same turn, so a check made before such a block still counts for the reply sent after it.
Every other prompt, including a watcher rewake, starts a new turn, so a check made during an earlier wake does not carry forward.

### Budget and the warned allow

The hook blocks at most `FM_LIVECHECK_BLOCK_BUDGET` consecutive times per session (default 2), which stays well below Claude Code's own eight-block ceiling even beside the supervision guard's budget.
The next stop after the budget is spent is allowed, and the hook tells the captain through a `systemMessage` which items stayed unverified, so a session can never loop and the gap is never silent.
Any allowed stop resets the count, including a reply that names nothing.
`stop_hook_active` is not a bypass: Claude sets it on every stop after any hook continuation, including watcher rewakes, so it cannot bound this hook; [`turnend-guard.md`](turnend-guard.md) records the same finding for the supervision guard.

### Scope and stand-downs

The hook guards exactly the primaries `bin/fm-primary-scope-lib.sh` admits: the main home and a validly marked secondmate home.
A crewmate or scout worktree working on firstmate itself stays inert, as does a Cursor-delivered payload through `bin/fm-hook-host-lib.sh` and a Grok hook process through the marker guard in the tracked entry.
A present `config/livecheck-off` opts a home out.
An absent payload, missing `jq`, or an unreadable transcript cannot be judged: the first two end the turn silently, and the third ends it with a `systemMessage` naming the items that were not confirmed.

## The one-call check

`bin/fm-verify-items.sh` takes any mix of the items above, including a reply pasted on stdin, and prints one line per item with its current state: a pull request's open, draft, merged, or closed state with its check rollup and review decision, an issue's state and reason, a Jira status category and status name, and a Jenkins build's building or result state.
GitHub goes through `gh` and GitLab through `glab`; Jira goes through REST when the credentials in `config/livecheck.env` are set and otherwise through the Atlassian `twg` CLI when installed; Jenkins goes through `curl` with the optional auth in the same file ([`configuration.md`](configuration.md#live-status-check-credentials-configlivecheckenv)).
The exit status is non-zero when any item came back `error` or `unverified`, and nothing it prints is a credential.

## Compatibility limits

- Claude is the only guarded primary harness.
  The decision needs the reply text and the turn's tool calls, which Claude's Stop payload supplies as `last_assistant_message` and `transcript_path`; no other primary integration delivers both, so Codex, OpenCode, Pi, pi-signed, omp, Grok, and Cursor remain unguarded by this rule.
- A lookup delegated to a subagent is not seen, because the main chain records only the subagent's report; the banner's own command is the direct path.
- A pull request number verified under one repository also verifies a bare reference with the same number, which is why bare references are discouraged.

## Transcript facts

The reader depends on the transcript shape Claude Code writes, observed on 2.1.296: one JSON object per line; user entries carry either a prompt (string content, or text blocks, with `isMeta` on skill loads and attachments) or `tool_result` blocks; assistant entries carry one `tool_use`, `text`, or `thinking` block each; subagent lines carry `isSidechain`; and attachment, system, and queue entries interleave with them.
Stop-hook feedback arrives as a prompt beginning with a `Stop hook feedback` task notification, both for a block and for the auto-arm's rewake, which is why the continuation rule keys on the banners rather than on the notification.
The transcript grows to hundreds of megabytes over a long session, so the reader takes growing tails from the end and never parses the whole file for an ordinary turn.

## Regression coverage

`tests/fm-livecheck-guard.test.sh` covers extraction of every item kind, the fence, quoted-span, wiki-link-text, and technical-token exclusions, bare-reference binding, the turn boundary and the continuation rule pinned against the real supervision guard's banner, the growing tail window with a deliberately non-vacuous fixture, the final-message fallback, every recognized and rejected lookup shape including a failed lookup that still counts, and the hook end to end: silence, the block banner and command, the quoted-title reply and the failed-lookup reply that both end the turn while a bare key still blocks, partial verification, the budget and warned allow, `stop_hook_active`, the transcript fallback, the unreadable-transcript warning, scope and host stand-downs, and the tracked registration.
`tests/fm-verify-items.test.sh` covers every backend over PATH fakes, the state mappings, bare references, the unverified and error lines, exit status, stdin, `config/livecheck.env`, the per-lookup bound, usage refusals, and that no credential reaches stdout or stderr.
`FM_LIVECHECK_LIVE_E2E=1 tests/fm-livecheck-guard-live-e2e.test.sh` is the opt-in guard that proves the payload shape and the block-then-allow cycle against the installed Claude Code and fails naming the harness and version.
[`verification/supervision.md`](verification/supervision.md#live-status-guard) records the active empirical evidence.
