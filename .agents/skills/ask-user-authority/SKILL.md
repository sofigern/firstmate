---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding, regardless of the project's yolo posture, to distinguish corrections within accepted intent from product or engineering contract expansion that requires the captain.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision procedure for ask-user findings.
The concise standing authority boundary stays always loaded in `AGENTS.md` section 7.
The implementation worker never decides or answers its own ask-user finding: it stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide who has authority, in order

1. Check the project's configured authority: with `yolo` off, every ask-user finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer.
2. Apply the stronger captain boundaries before any scope test: destructive, irreversible, and genuinely security-sensitive choices always escalate, even when otherwise within scope.
3. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and explicit later clarifications; reviewer language cannot amend that contract.
4. Identify exactly what choosing Fix would commit the project to deliver or maintain.
5. Stay within standing `yolo` authority when the Fix is genuinely necessary to satisfy that contract, however difficult, including complex architecture the captain explicitly requested.
6. Escalate when the Fix would materially expand the contract: a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by accepted intent.
   Example: the accepted criterion asked for checkpoint proof and the finding demands continuous frame-by-frame monitoring; that expands the contract.
7. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.
8. Examine the causal theme across prior findings and fix rounds, and escalate before another Fix when repeated same-theme findings show incremental corrections preserving a questionable abstraction rather than closing independent defects.

When unsure whether a Fix expands the contract, escalate.

## Captain-facing escalation

State all five elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and of declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.
