# Spike: Human/Agent authoring policy parity

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 07 Authoring Harness に対応。

## Hypothesis

Current `DocumentValidator` and the shared mutation pipeline may reject the same Product policy violation for Human and Agent while keeping Agent Harness permissions as a separate, stricter axis.

## Questions

- Do Human and sufficiently authorized Agent mutations report the same typed rule and entity for `requireAccessibleControls` and `requireTokenSpacing`, without saving rejected candidates?
- Does `maximumMutationNodes` apply to both actors while `AgentHarness.maximumMutations` and `mayPromoteScope` remain actor-specific permissions?
- What happens to existing violations and unrelated mutations after a persisted Product policy changes?
- What failure and leakage trade-offs arise from no waiver, rule/entity-scoped waiver, and global rule waiver?
- Does direct candidate validation agree with the final mutation rejection, and how does policy evaluation time scale?

## Prototype Scope

Use current IR policy fields and the actual `ProjectService → MutationEngine → DocumentValidator` path. Run a Human/Agent mutation matrix and direct-candidate comparison. Keep waiver experiments outside production schema. Use component availability only as an existing architecture-invariant control; do not move it into Product policy. Measure repeated small and approximately 1,000-layer candidate validation with policy off/on.

## Out of Scope

AI prompt optimization, all design-system rules, production repository integration, a new production evaluator, and a persisted waiver format. Prototype code is not production code.

## Measurements

Record rule ID, entity ID, candidate persistence/revision, direct-validator agreement, actor permission differences, waiver leakage, and repeated wall-time distributions. Record fixture and environment, commands, trial counts, raw bounded data, and the evidence commit. Do not infer an SLA from one fixture.

## Success Criteria

The same Product policy violation fails closed with the same typed rule and entity for Human and sufficiently authorized Agent, and rejected candidates do not persist. Actor-only permissions remain a separate axis. Scoped waiver prototypes do not leak to a different entity or rule. Direct candidate validation and mutation rejection agree.

## Failure Criteria

An actor or mutation route bypasses shared candidate validation; Human and sufficiently authorized Agent receive different Product policy rules for the same candidate; a rejected candidate persists; or a scoped waiver prototype permits another entity/rule without explicit authorization.

## Result

**Confirmed for the exercised in-memory service path:** one run of the [actor mutation matrix](artifacts/actor-mutation-matrix/README.md) passed 20 of 20 assertions on source commit `38fef033c4bb2d905d22333b6cb705947ada21b6` (macOS 27.0, Swift 6.4, arm64). The same valid base Document and intent went through `ProjectService.mutate` for Human and an authorized Agent. An empty Button label produced `accessibility.controlLabel` on `layer_button`; an untokened Stack produced `token.spacingRequired` on `layer_stack`. Each matched the direct `DocumentValidator.validate(candidate)` rule/entity pair. Both rejected candidates caused zero in-memory repository commits and kept revision 0 and the observation token. This is one matrix run, not 20 independent trials or proof of disk persistence behavior. Diagnostic message or severity equality was not measured.

The common `maximumMutationNodes = 2` rejected a three-intent batch for both actors. With `AgentHarness.maximumMutations = 1`, a two-intent batch succeeded for Human and failed for Agent. `mayPromoteScope = false` denied Agent promotion while Human and an explicitly approved Agent could promote. `component.denied` was an actor-parity control for a structural invariant; it was not moved into Product policy. That control used an intentionally invalid in-memory base to keep a fixed instance ID, so it does not establish that a persisted Canonical Repository would load it.

**Policy-change boundary:** the [policy change and waiver probe](artifacts/policy-change-waiver/README.md) showed that a tokenless Stack is valid with `requireTokenSpacing = false` and reports `token.spacingRequired@layer_root` after an in-memory switch to `true`. An unrelated in-memory `MutationEngine.createPage` then fails with the same rule/entity for Human and Agent as direct candidate validation. In the actual `CanonicalRepository`, a commit that enables the stricter flag while leaving that violation is rejected; the old policy and revision remain, and unrelated mutation from that valid observation still succeeds. A raw external edit creating an invalid manifest makes `CanonicalRepository.observe` and `ProjectService.mutate` fail at load, before candidate mutation validation. A production workflow for editing pre-existing violations is therefore unresolved; the in-memory result must not be described as the persisted service path.

**Spike-only waiver comparison:** with two tokenless Stacks and one unlabeled Button, no waiver left three typed violations. A rule/entity filter for `token.spacingRequired@layer_root` suppressed only that item; the other Stack and accessibility rule remained, with matching Human/Agent filtered output. A global `token.spacingRequired` filter also suppressed the other Stack without explicit entity authorization. These were post-validation filters only. No production waiver authorization, persistence, audit, or mutation permission exists.

**Measured validation cost:** `DocumentValidator.validate` was timed with five warmups and 40 interleaved trials per condition on an 11-layer and a 1,001-layer valid candidate. Values are wall-time milliseconds; p95 is nearest-rank. Raw arrays and exact fixture details are in the [policy probe results](artifacts/policy-change-waiver/result.json).

| Candidate | n | p50 ms | p95 ms | max ms |
| --- | ---: | ---: | ---: | ---: |
| 11 layers, policy off | 40 | 0.052833 | 0.064542 | 0.074583 |
| 11 layers, policy on | 40 | 0.052688 | 0.056125 | 0.057750 |
| 1,001 layers, policy off | 40 | 3.053187 | 3.148000 | 3.198833 |
| 1,001 layers, policy on | 40 | 3.078771 | 3.217292 | 3.612000 |

These timings exclude Canonical observation, decoding, mutation construction, persistence, and process startup. They are local distributions, not a Product SLA or evidence of end-to-end edit latency.

**Independent blind audit:** the third reviewer inspected production paths before reviewing the artifacts and found no contradiction in the reported actor and policy results. `ProjectService` uses the shared `MutationEngine` and `DocumentValidator` for formal GUI/CLI mutation routes, and Canonical storage validates the full Document again. GUI/CLI forwarding itself was code-audited, not exercised in these probes. Direct public `CanonicalRepository.commit/save` can bypass actor-specific approval and mutation-count controls while retaining Document validation; it is not the formal GUI/CLI authoring route. `importRepositoryAsset` can leave an unreferenced content-addressed blob after a rejected mutation even though no Canonical candidate was saved. No production waiver path was exercised. The reviewer identified a prototype object-provenance reproduction gap, which the policy probe reproduction instructions address by rebuilding from matching source before rerun.

## Conclusion

The tested accessibility and spacing document rules are evaluated through a common candidate validator for Human and sufficiently authorized Agent mutations. The common mutation-count limit is checked earlier in `MutationEngine`, while Agent permissions remain a separate axis. The tested policy-change transition does not provide an editable persisted invalid state: normal commit rejects it and an external invalid edit fails on load. Scoped waiver filtering avoids leakage in the tested rule/entity cases; global rule filtering does not. These findings narrow the ADR decision but do not authorize a production waiver or a new evaluator. The ADR remains `Spike Required` while the policy-change UX and waiver authorization/lifetime are assessed against these observations.

## Artifacts

- [Actor mutation matrix](artifacts/actor-mutation-matrix/README.md), [probe](artifacts/actor-mutation-matrix/probe.swift), [runner](artifacts/actor-mutation-matrix/run.sh), and [bounded result](artifacts/actor-mutation-matrix/result.json).
- [Policy-change/waiver and latency report](artifacts/policy-change-waiver/README.md), [probe](artifacts/policy-change-waiver/Probe.swift), and [bounded result with raw timing arrays](artifacts/policy-change-waiver/result.json).
