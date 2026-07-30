---
name: slack-request
description: >-
  Agent-only contract for questions and support requests that originate in Slack.
  Use when the captain asks for a reply or draft to a Slack thread or support channel, however tersely.
  Owns the standing depth-and-evidence mandate injected into the dispatched worker, the experiment cost boundary, and the thin Slack-specific delivery rules for drafting, reviewing, posting, and correcting under the captain's identity.
user-invocable: false
metadata:
  internal: true
---

# slack-request

Load this when a question or support request originates in Slack, including invocations as terse as "with this skill, reply to the support channel".
That sentence is the whole instruction: everything below follows without further captain input.
If `data/procedures/slack-requests.md` exists in this home, read it now; it owns the workspace detail (finding a thread from dictated references, recurring people, channels, footer text) that this fleet-general skill omits.
Slack and other interactively authenticated sources usually ride on this session, so firstmate gathers the thread and posts, while the investigation itself is dispatched.

## Dispatch

The answer is produced by a dispatched worker carrying the mandate below, never inline from firstmate's or the model's own knowledge.
Classify the ask with the section 7 intake contract, and load `diagnostic-reasoning` before scoping anything that is a reported bug; a Slack request is evidence, never authorization to change code.
Give the worker the located thread content, its cross-posted siblings, and the requester's identity as inputs.
Inject the mandate section into the brief verbatim, or reference this file by absolute path with an instruction that the mandate is binding; never paraphrase it thinner.

## Mandate for the dispatched worker

You are answering a colleague-facing or customer-facing question, and a confident wrong answer costs more than a slow one, so truth outranks speed everywhere below.

- Never answer from your own model knowledge; every claim in the reply must trace to evidence you gathered in this investigation.
- Exhaust the internal record before reaching outward: the thread and its cross-posted siblings, the channel's history of the same question, and the prior support history of both the question and the person asking, because what they were told before changes the right answer now.
- Jira and Confluence, through Rovo and the Atlassian tools, are in scope and not optional: meta documentation, tickets touching the same subsystem, and epics whose stated premises may be stale.
- MCP tools generally are expected instruments, not exotic ones; if an authenticated source is unreachable from your session, report that exact gap so firstmate covers the read, and never silently skip the source.
- Where behavior is the question, the authority is the code and the running system: read the code, and prefer a live request or a metrics query over an inference.
- Experiments and benchmarking are encouraged, not exceptional: never conclude from metadata or documentation what a small experiment can prove.
- Cost boundary: up to roughly ten dollars of one-off metered spend per investigation needs no permission; anything beyond that, any resource that keeps billing after the experiment (a provisioned cluster, a subscription or tier change), and anything whose cost you cannot estimate needs the captain first.
- Regardless of price, spending against production credentials and anything that writes to a production system always need approval; tear down whatever you spin up.
- Verify every external product, platform, pricing, or API claim against current official documentation and carry the citable link into the report, because the model's memory of these is stale by construction.
- Separate measured from published from assumed, and state unknowns as unknowns: a clearly marked gap is more useful than a plausible number.

## Delivery

Slack mrkdwn is not GitHub Markdown: bold is single `*asterisks*`, italic is `_underscores_`, links are `<url|text>`, and headings do not render.
Write to the captain's voice and writing profiles; the workspace procedure file records where they live.
Anything posted under the captain's identity ends with the captain's standing attribution footer as its own paragraph.
The captain reviews the draft rendered in Slack itself (a draft message or a direct message), never as console text, because console formatting differs from Slack's rendering.
Posting under the captain's identity in a shared channel is outward-facing: the captain decides per message whether it posts and who posts it, the agent or the captain themselves.
After posting, verify the rendered formatting and the footer on the live message.
A posted answer that later needs an in-thread correction is a normal outcome, not a failure: draft and review the correction the same way, lead with what changed and why, and never silently edit the original.
