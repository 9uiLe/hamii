# Authoring Harness の共通 policy 実行

## Context

Prompt だけの規則は Human と AI に同じ制約を適用できず、直接 mutation の抜け道を生む。

## Decision to Make

versioned Authoring Harness をどの mutation/validation boundary で実行し、waiver をどう記録するか。

## Constraints

Human/AI 共通 policy。Actor Harness の権限と Authoring Harness の製品ルールを分ける。

## Options

Shared `DocumentValidator` for document-state rules plus actor-independent `MutationEngine` operation limits; a separate pure evaluator called from the same shared pipeline; actor-side prechecks; or prompt-only guidance.

## Current Hypothesis

The common candidate-validation hypothesis is resolved by the Decision below. The Spike measured rule/entity parity for the current accessibility and spacing rules; it did not establish a need for a separate evaluator type.

## Decision

Authoring Harness Product policy is enforced in the shared authoring pipeline, independently of whether a Human, CLI, or Agent submitted an intent. Document-state rules such as `requireAccessibleControls` and `requireTokenSpacing` use full-candidate `DocumentValidator` validation as their authority. Operation-shape rules such as the current `maximumMutationNodes` batch limit are actor-independent checks in `MutationEngine`. `AgentHarness.maximumMutations` and `mayPromoteScope` remain additional actor permissions. GUI/CLI prechecks, AI instructions, and skill text may explain or anticipate a result but cannot replace this authority. A future pure `AuthoringPolicyEvaluator` helper is allowed if it preserves this boundary; this Decision does not require one.

Canonical storage accepts only Documents valid under their current Authoring Harness. Enabling a stricter policy is rejected if the resulting candidate leaves pre-existing violations. A caller can first remediate under the old policy; a future policy-edit intent may combine remediation and policy change in one valid atomic candidate. Persisting an invalid intermediate Document for a repair-mode workflow is not part of this Decision. A direct external edit that makes Canonical data invalid remains fail closed at load.

Authoring Harness v1 has **no production waiver**. Violations remain blocking. The Spike's rule-ID plus exact entity-ID filter did not leak in its tested cases, while a global rule filter suppressed a second entity without explicit authorization. These prototype filters do not authorize a mutation or define a persisted schema. If a future feature needs waivers, authorization, storage, audit, lifetime, and migration require a separate decision; begin from an exact rule/entity scope rather than a global rule waiver.

## Unknowns

- A future waiver feature's authorization, storage, audit, lifetime, and format migration. No waiver is part of Authoring Harness v1.
- The optional shape of a pure evaluator extraction and future policy rule extension. Neither is required for the current Decision.
- Severity/message parity, full GUI/CLI forwarding regressions, and end-to-end mutation latency have not been measured by the Spike. Typed rule/entity parity, persistence, and fail-closed loading still need permanent production tests.

## Required Evidence

The [actor policy parity Spike](spikes/actor-policy-parity/SPIKE.md) is preserved in commit `95798d4f77e1227ea737f04f7b687981b563d53f`. It measured the Human/Agent rule/entity matrix, common versus Agent-only limits, stricter-policy transition, three waiver filters, and candidate-validation wall time. An independent reviewer audited its claims and source paths. The Evidence supports this Decision but does not establish a production waiver, invalid-state repair mode, or GUI/CLI end-to-end parity.

## Decision Criteria

The Decision is satisfied by the tested common policy boundary, the fail-closed Canonical policy-change behavior, and the explicit absence of waivers in v1. Implementation is complete only after permanent tests cover Human/authorized-Agent typed rule/entity parity and rejected-candidate non-persistence; common and Agent-only limits; stricter-policy commit rejection with unchanged Canonical state; and external-invalid-data load rejection. Current Architecture documentation must state these rules without relying on this ADR. Evaluate ADR deletion only after implementation and validation are committed separately, following the [ADR workflow](../../docs/adr-workflow.md).

## Status

Implementation Required
