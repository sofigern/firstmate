---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain decisions.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Durable unresolved-decision lifecycle

This skill is the single policy owner for unresolved captain decisions discovered by an investigation or visual review.
The originating work or review is not complete until this lifecycle has run, and no visual tool, including Lavish, owns a parallel completion policy.
Run every command in the originating work's authoritative `FM_HOME`: a secondmate-owned decision is held in that secondmate home's backlog, never copied into the main backlog.

## Sequence

1. Read the complete investigation result and finish the visual review before declaring either complete.
2. Inventory the whole report and review surface yourself for unresolved choices that genuinely require the captain; scripts never infer decisions from prose, artifacts, terminal output, or chat.
3. Register each distinct decision with `bin/fm-decision-hold.sh hold` under a stable privacy-safe key, with a concise title, reason, and repository; reuse the same key on retry so registration is idempotent.
4. Run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section, following `AGENTS.md` section 9; do not use the word hold in captain chat.
6. After the captain decides, record dependent work with normal tasks-axi commands in the same backlog and block it by the hold identity.
7. Put the captain's exact durable decision in a file, then close the hold with `bin/fm-decision-hold.sh resolve` and every routed task.
8. Confirm Bearings no longer shows the closed hold and that routed work remains in structured backlog state.

## Boundaries

Never close a hold because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold stays the authoritative Captain's Call item until the captain's answer is durably recorded and routed; no path stands in for an answer the captain has not given.
Bearings reads only the resulting structured state; never compensate by scraping historical reports, visual-review artifacts, terminal output, or chat.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like create no hold.
When unsure whether a choice genuinely requires the captain, register it; an extra captain question is recoverable while a lost decision is not.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
