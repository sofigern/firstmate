---
name: model-selection
description: >-
  Terse rubric for choosing the crew Claude model (Haiku, Sonnet, Opus, Fable) at crewmate/scout dispatch intake.
  Load before choosing the model for a crew or scout dispatch.
user-invocable: false
metadata:
  internal: true
---

# model-selection

Load before choosing the model for a crew or scout dispatch, when no captain override or `config/crew-dispatch.json` profile already names one.

- Haiku (cheapest/fastest) - mechanical, single-decision, cheap-to-verify edits: a named version/tag bump, a single config/BUILD/doc edit, a spelled-out diff, posting an approved message.
  No debugging.
- Sonnet (balanced default) - standard implementation, scoped migration, scout/inventory work, pattern-following code, composition-quality writing.
  The default workhorse.
- Opus - hard reasoning, genuine ambiguity, multi-step design, tricky debugging, high-stakes correctness.
- Fable (premium, deliberate) - only the very hardest long-horizon work where Opus is not enough.

Default: mirror the crew/dispatch default; escalate a tier for hardness or high stakes, drop a tier for mechanical/cheap-to-verify work.
Unsure: pick Sonnet, then move to Opus if the task involves real reasoning or a costly mistake.
A per-task captain override always wins; effort is a separate axis owned by `harness-adapters`, not restated here.
