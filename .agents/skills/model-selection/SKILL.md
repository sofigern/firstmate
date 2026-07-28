---
name: model-selection
description: >-
  Terse rubric for choosing the crew Claude model (Haiku 4.5, Sonnet 5, Opus 4.8, Fable 5) at crewmate/scout dispatch intake.
  Load before choosing the model for a crew or scout dispatch.
user-invocable: false
metadata:
  internal: true
---

# model-selection

Load before choosing the model for a crew or scout dispatch, when no captain override or `config/crew-dispatch.json` profile already names one.

- `claude-haiku-4-5` (cheapest/fastest) - mechanical, single-decision, cheap-to-verify edits: a named version/tag bump, a single config/BUILD/doc edit, a spelled-out diff, posting an approved message.
  No debugging.
- `claude-sonnet-5` (balanced default) - standard implementation, scoped migration, scout/inventory work, pattern-following code, composition-quality writing.
  The default workhorse.
- `claude-opus-4-8` - hard reasoning, genuine ambiguity, multi-step design, tricky debugging, high-stakes correctness.
- `claude-fable-5` (premium, deliberate) - only the very hardest long-horizon work where Opus 4.8 is not enough.

Default: mirror the crew/dispatch default; escalate a tier for hardness or high stakes, drop a tier for mechanical/cheap-to-verify work.
Unsure: pick Sonnet 5, then move to Opus 4.8 if the task involves real reasoning or a costly mistake.
A per-task captain override always wins; effort is a separate axis owned by `harness-adapters`, not restated here.
