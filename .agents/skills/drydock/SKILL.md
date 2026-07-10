---
name: drydock
description: Periodic deep compaction of firstmate's accumulated knowledge and files - the weekly haul-out that keeps the home lean and operable. Use when the captain invokes /drydock (e.g. "/drydock", "weekly compaction", "summary of the week", "compact your knowledge", "clean up the fleet's memory or disk"). Consolidates learnings to their essential rules, merges duplicates, graduates recurring procedures into skills or the operator's global config, interviews the captain on which projects to keep, and prunes stale files - with every destructive step proposed and confirmed before it happens.
user-invocable: true
metadata:
  internal: true
---

# drydock

Take the fleet into drydock: a periodic, captain-supervised deep compaction of everything this home has accumulated - learnings, per-task artifacts, project clones, and the `data/*.md` files - so the next week starts lean.
`/stow` captures a session's knowledge onto disk; `/drydock` is its heavier periodic counterpart that curates what all those captures have piled up, and deliberately forgets what is dead.
Run it roughly weekly, or whenever the home's size or `data/learnings.md`'s length starts degrading operability.

## Operating requirements

- This is a judgment-heavy curation task: run it on the heaviest reasoning model available, `fable` today.
  If the current session is on a lighter model, tell the captain and let them choose between proceeding anyway and re-invoking from a fable session.
- Prefer a quiet fleet: with no crewmates in flight, firstmate may edit shared tracked material directly per AGENTS.md section 1, and nothing races the `data/` rewrites.
  With work in flight, still run the `data/` and disk phases, but delegate any tracked-material change to a crewmate as section 1 requires.
- This is a decision framework, not a script: every phase produces a proposal, and nothing destructive or irreversible (deleting knowledge, deleting files, dropping a project, writing to the operator's config) happens before the captain confirms it.
- If the current session holds uncaptured knowledge, run `/stow` first so this compaction works from complete on-disk state.

## Phase 0 - survey and stage

1. Measure: `du -sh` the home and its top offenders (`projects/`, `data/`, `state/`, `.lavish/`), and note the line count of `data/learnings.md`.
2. Inventory `data/`: every `<id>/` task dir, every loose doc, every dated report, and the four registry files.
3. Stage a backup before anything is rewritten or deleted: archive `data/` to a dated tarball outside the home (for example `$TMPDIR/fm-drydock-<date>.tar.gz`), and tell the captain where it is.
   The backup is the undo button for this run; it can be discarded at the next drydock.

## Phase 1 - knowledge triage

Read `data/learnings.md`, `data/captain.md`, and every loose doc under `data/`, and classify each entry:

- **Forget-forever**: stale, one-off, superseded, or tied to a project or tool that is gone.
  Propose deletion; do not archive prose that will never be read again.
- **Keep-as-essential**: a durable rule.
  Rewrite it down to the do-or-don't plus the one fact that makes it credible; drop the incident narrative and history.
- **Keep-with-context-for-now**: recent (roughly the last two weeks) and still settling.
  Keep a brief why, and expect the next drydock to demote it to essential or forget it.

Merge repetitive entries into one consolidated entry - the one-owner rule applied to `data/learnings.md`: one rule, stated once, owning its topic.
Present the whole triage as one compaction plan (before/after entry counts, the forget list verbatim, the merged rewrites) and get the captain's confirmation before writing anything.
Use lavish-axi when the plan is large enough to need a review surface; chat is fine for a small one.

## Phase 2 - graduation

While triaging, watch for clusters of entries that together describe a durable recurring procedure rather than isolated facts.
A procedure should live as a skill or doc, not as prose scattered through learnings.
Route each graduation by scope, using AGENTS.md section 6's knowledge-routing table as the single owner of placement - never re-derive it here:

- **Operator-global**: useful to the operator across all their work, not firstmate-specific (for example a ticket-filing recipe they use everywhere).
  It graduates up and out of firstmate into the operator's own global agent configuration - their dotfiles, global instruction files, or personal skills, in whatever form they already maintain.
  Firstmate is a shared template: never assume or hardcode any particular operator's paths or personal skills; ask the captain where their global config lives and whether they want the content written there, handed over as a draft, or fed to their own capture tooling.
  Writing outside this home is destructive-adjacent: only with the captain's explicit go-ahead, and inspect-then-update at the destination, never blind appends.
- **Generalizable to every firstmate user**: shared tracked material, shipped via the pipeline - a new `.agents/skills/` skill with a proper inline trigger, or a `docs/` reference, per the `firstmate-coding-guidelines` placement tree (load it before authoring).
- **Fleet-local**: a procedure private to this captain that still deserves structure.
  Tracked skills cannot hold captain-private material, so write it as a dedicated doc under `data/` (for example `data/procedures/<name>.md`) and leave a one-line pointer in `data/learnings.md`.

This is the deliberate skill-authoring path that `/stow`'s no-skill-storage exclusion defers to; a stow sweep never creates skills, a drydock graduation may.

## Phase 3 - project and mission continuation (interactive)

Do not guess which projects are alive; ask.
List every project from `data/projects.md` with its clone size, last activity (recent backlog items, git log recency), and any secondmate whose scope covers it, and ask the captain per project: continue, pause, or drop.
Use lavish-axi's input playbook when the list is long.

For each captain-confirmed drop:

1. Check the clone for unlanded work first - dirty files or local branches not reachable from any remote - and surface anything found before proceeding; the captain must explicitly discard it.
2. Drop its `data/projects.md` registry line - that file is firstmate's own, so this is a normal write, never a state-changing command under `projects/`.
3. Present the exact removal command (for example `rm -rf projects/<name>`) for the captain to run themselves to reclaim the clone's disk; firstmate never runs a state-changing command under `projects/`, so it does not delete the clone itself.
4. Forget its learnings and loose docs, and close or delete its queued backlog items.
5. If a secondmate exists solely for that scope, propose retiring it; the retirement itself follows the normal secondmate teardown path (load `secondmate-provisioning`), never an ad-hoc delete.

Paused projects keep their registry line (marked paused) but their knowledge compacts to essentials like everything else.

## Phase 4 - file and disk pruning

Propose, confirm, then delete:

- Per-task `data/<id>/` dirs whose task is long finished: the brief is always disposable once the task is done; a `report.md` is disposable only when nothing references it.
  Check `data/backlog.md` Done entries and `data/done-archive.md` for report paths before touching any report; a still-referenced report is kept, or archived with its reference updated, or explicitly cleared with the captain - never silently deleted.
- Orphaned per-task `state/<id>.*` files whose task has no meta and no backlog presence; leave the watcher's own internals alone (AGENTS.md section 2 marks them never-touch).
- Dated artifacts that have served their purpose: old `data/status-report-*.md` files, stale `.lavish/` artifacts, previous drydock backups.
- Anything else large and redundant the survey turned up, judged case by case.

The target is a home comfortably under 1GB; the captain's removal of dropped project clones (phase 3) is the usual biggest reclaim, alongside accumulated task dirs.

## Phase 5 - apply the rewrites

With the plan confirmed, rewrite the registry files into their compacted form using inspect-then-update: `data/learnings.md`, `data/captain.md`, `data/projects.md`, and `data/secondmates.md`.
Fold any knowledge the triage promoted to every-session relevance into its routed home: only genuinely every-turn facts go inline in the shared `AGENTS.md`, everything else becomes a skill or doc, and all tracked-material changes ship through the normal pipeline (branch, no-mistakes, PR, captain merge).

## Phase 6 - report

Close with a before/after report in plain outcome language: home size before and after, learnings entry count before and after, what was forgotten, what graduated and to where, which projects were dropped or paused, and where the backup tarball lives.
If tracked-material changes are in flight through the pipeline, name them as pending rather than done.
