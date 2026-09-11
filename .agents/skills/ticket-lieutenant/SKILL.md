---
name: ticket-lieutenant
description: >-
  Agent-only contract for one window per ticket.
  Use at intake whenever a request names or follows up a ticket, before opening a ticket window or steering a request into a live one, when a lieutenant reports a request done or asks for a decision, and before closing a ticket window.
  Owns what a ticket is, how a request is routed to its window, when a separate window is still right, what a lieutenant's subagents mean for supervision and recovery, and how a ticket closes.
user-invocable: false
metadata:
  internal: true
---

# ticket-lieutenant

`AGENTS.md` section 7 carries the always-inline rule: one window holds one ticket in one project for the ticket's whole life, a request about a live ticket is steered to that window, and a ticket window is opened once with `--ticket`.
This skill owns the rest of firstmate's side.
The worker's side is owned by the `# Ticket` section `bin/fm-brief.sh --ticket` generates; do not restate it in a steer.

## What a ticket is

- A Jira key when one exists (`KD-1950`, `IN-3386`); otherwise a PR under review (`PR-24375`); otherwise a workstream the captain has named, in his words rather than a slug you invent.
- Work with none of those is an ordinary task named by a slug; a follow-up to it still goes to its live window, because the rule is about live work, not only tickets.
- The task id is the key lowercased (`kd-1950`, `pr-24375`), so the window is `fm-kd-1950`; a ticket reopened after its window closed takes the key plus `-2`.
- One window per ticket per project: the same ticket in a second project gets a second lieutenant named `<key>-<project>`, and both briefs record the same key.

## Routing a request

Run this before every spawn, not only when the request mentions a key.

1. Name the request's ticket: the key the captain said, or the referent he used (a PR, a report, a Jira comment, a service) that belongs to a live ticket window, or the subsystem a live ticket window is already working in.
2. Find the live window: `grep -il '^Ticket contract: key=<KEY> ' data/*/brief.md`, keeping only ids whose `state/<id>.meta` exists.
   A parked, paused, or idle lieutenant still holds its ticket.
3. Live window in that project: steer it with `bin/fm-send.sh <id> <request>` and record the request in the ticket's backlog item note.
   The steer carries the captain's words, a request slug the lieutenant keys its status by, the deliverable (a change, a report, a write such as a Jira comment), and the mode and ready signal when the request's delivery mode differs from the ticket's standing one.
   Do not spawn, and do not promote a lieutenant: it is already ship-shaped and moves from investigation to implementation on your word.
4. No live window: scaffold `bin/fm-brief.sh <key-lowercased> <project> --mode <standing mode> --ticket <KEY>` with the first request in the Task section, then spawn as for any ship task.
   The scaffold refuses a same-project live holder itself; a refusal means step 2 was wrong, so steer that holder.
5. A request spanning two tickets is split by ticket, one steer or window each; a request about no ticket is an ordinary task.

## When a separate window is still right

- A different project: a worktree is per project, so the same ticket's work in a second repo is a second lieutenant, named `<key>-<project>`.
- The captain's explicit word to split the ticket's work: pass `--second-window` and quote his words in the backlog note.
- Work that must outlive the ticket: a persistent domain is a secondmate, and a different ticket is its own window; a production watch after a merge stays with the ticket's lieutenant or with your own check, never a new window.
- Genuinely independent work that shares no ticket, PR, or workstream.

Not a reason: a different kind of request (a Jira comment, a PR, a migration), a lieutenant that is busy or waiting (queue it, or it fans out), or parallelism (its subagents).

## Supervising a lieutenant

- Status is keyed per request; `done [key=<slug>]` closes that request only.
  An idle lieutenant afterwards is healthy, exactly like a secondmate's idle endpoint: expect one stale notification and then quiet, and acknowledge an inactive-outcome notification for it without cleanup.
- PR ready: `bin/fm-pr-check.sh` records one `pr=` per task and a later registration replaces the merge poll.
  Arm it on the PR whose merge you must act on next, and ask the lieutenant for the state of its other open PRs when you need it; extending the poll to several PRs per task is a tooling change, not something to work around by opening windows.
- A decision from a lieutenant holds the ticket's one backlog item through `bin/fm-captain-hold.sh hold <id>`; several open questions on one ticket are one held item listing all of them (`captain-hold-lifecycle`).
- Subagents are invisible to you: they write no metadata, no status, and take no steer.
  Steer only the lieutenant, and let it relay.
- A relaunch loses any subagent work in flight; the ticket ledger at `data/<id>/report.md` is the recovery input.
  Relaunch through `stuck-crewmate-recovery` as for any crewmate, then confirm the lieutenant read the ledger before it acts.
- Fan-out needs an in-session agent tool.
  Claude has one, and the delegation guard leaves it available in a task worktree (`docs/subagent-guard.md`); Codex has none, and the other harnesses are unverified there, so such a lieutenant does the work itself while the one-window rule still holds.
- A request that arrives during a validation run and does not touch the branch under validation may proceed at once; one that does queues behind the run, or, when it invalidates the run, follows section 7's supersession sequence.

## Closing a ticket

- Close only on the captain's word that the ticket is done or the window should go; idle time, a Jira transition you noticed, and your own reading of completion are not that word, and closing his window is his call.
- Before cleanup, ask the lieutenant for its branch inventory and read `git -C <worktree> branch -vv` yourself: `bin/fm-teardown.sh` checks only the checked-out branch and uncommitted changes, so an unlanded side branch would be discarded silently.
  Every branch must be landed, deleted, or explicitly named by the captain for discard.
- Then run the ordinary teardown and record the ledger path with the ticket's PRs as the Done artifact.
