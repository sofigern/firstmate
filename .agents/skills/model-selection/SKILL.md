---
name: model-selection
description: >-
  Agent-only rubric for choosing the crew Claude model tier (Fable 5, Opus 5, Sonnet 5, Haiku 4.5) for a crewmate or scout dispatch.
  Load before choosing the model for a crew or scout dispatch.
user-invocable: false
metadata:
  internal: true
---

# model-selection

This skill is the general, committed rubric firstmate loads at intake to reason about which Claude model tier fits a kind of work.
It complements `config/crew-dispatch.json`, the captain's per-fleet override, rather than replacing it.
`AGENTS.md` section 4 and `docs/configuration.md` own `config/crew-dispatch.json` mechanics and schema; this skill does not restate them.

Resolution precedence, unchanged from `AGENTS.md` section 4 and `harness-adapters`:

1. An explicit per-task captain instruction for this dispatch always wins.
2. A matched `config/crew-dispatch.json` rule or default profile's `model` field wins next.
3. When no profile names a model, apply this skill's rubric to choose one.
4. Absent all of the above, the selected harness's own default model applies.

This skill only fills step 3.
It never overrides a captain instruction or a configured profile, and it is silent when a profile already names a concrete model.

## Current model facts

Verified against the Claude models overview (`https://platform.claude.com/docs/en/about-claude/models/overview.md`), fetched 2026-07-28.
Treat that page as the freshness source of truth over this table; re-fetch it if these facts look stale, and update this table rather than trusting memory.

| Model | Claude API ID | Tier purpose | Pricing (in/out per MTok) | Context | Notes |
|---|---|---|---|---|---|
| Claude Fable 5 | `claude-fable-5` | Most capable widely released model, for the most demanding reasoning and longest-horizon agentic work | ~$10 / $50 | 1M tokens | Always-on adaptive thinking; the premium tier, use sparingly given cost |
| Claude Opus 5 | `claude-opus-5` | Complex agentic coding and enterprise work | ~$5 / $25 | 1M tokens | Current top Opus tier as of the 2026-07-28 fetch; supersedes Claude Opus 4.8 (`claude-opus-4-8`), which the same page now lists under legacy models at the same price and remains a fallback if `claude-opus-5` is ever unavailable on a given harness |
| Claude Sonnet 5 | `claude-sonnet-5` | Best combination of speed and intelligence | ~$3 / $15 (introductory $2 / $10 through 2026-08-31) | 1M tokens | The workhorse default for most crew work |
| Claude Haiku 4.5 | `claude-haiku-4-5-20251001` | Fastest model with near-frontier intelligence | ~$1 / $5 | 200K tokens | Predates the dateless-ID generation, so the exact API ID carries the date suffix; `claude-haiku-4-5` is the convenience alias, and a harness that requires the exact dated ID may reject the bare alias |

Do not invent a model name or tier beyond what current authoritative discovery (this table, or the harness's own model listing per `harness-adapters` "Model support discovery") establishes.
If a harness's model listing does not offer one of these exact IDs, fall back to that harness's nearest equivalent tier rather than guessing a name.

## Task shape to model tier

This generalizes the same spirit as [`docs/examples/crew-dispatch.json`](../../../docs/examples/crew-dispatch.json), so a captain-authored `config/crew-dispatch.json` and this skill's judgment do not contradict each other.

- **Haiku 4.5** - mechanical, single-decision-point, cheap-to-verify edits: a named version/tag bump, a single config/BUILD/doc edit, a spelled-out diff, posting an already-approved message.
  No debugging is involved and a mistake is cheap to catch and undo.
- **Sonnet 5** - the default for most crew work: standard implementation, scoped migrations, inventory/scout work, code following a clear pattern, and composition-quality writing where voice or attribution matters.
  Also use it for mechanical-but-prod-facing work where a mistake compounds, even though the steps themselves are simple.
- **Opus 5** - hard reasoning, genuine ambiguity, multi-step design, tricky debugging, long-horizon autonomous work, or high-stakes correctness where a wrong answer is expensive.
- **Fable 5** - only the very hardest, most demanding reasoning or longest-horizon agentic work, where Opus 5 is genuinely not enough.
  Flag the cost explicitly in the dispatch rationale so reaching for it is a deliberate choice, never a default.

## Weighing cost against capability

Escalate a tier only when the task's ambiguity, blast radius, or debugging depth genuinely needs it, not because more capability is always safer.
A wrong-tier-too-low outcome costs a redo; a wrong-tier-too-high outcome costs money on every dispatch, so prefer the lowest tier that plausibly gets the task right the first time.
When genuinely unsure between two adjacent tiers, prefer the cheaper one for a low-blast-radius task and the stronger one for a high-stakes or hard-to-verify task.

## Model is one axis; effort is a separate one

`--model` and `--effort` are independent `fm-spawn` flags.
`harness-adapters`' "Launch profile axes" section owns the effort fallback table and precedence; do not restate it here.
Choosing a strong model does not substitute for choosing an appropriate effort level, and vice versa.

## Safe default

Absent a clear reason to escalate or downgrade, mirror the crew harness's own default model (or the configured `config/crew-dispatch.json` default profile) rather than picking a tier from first principles on every dispatch.
Escalate above that default for genuine ambiguity, design work, or high-stakes correctness; downgrade below it only for clearly mechanical, cheap-to-verify work.
A per-task captain override always wins over this rubric, as stated in the resolution precedence above.
