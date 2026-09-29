# Adaptive read candidates

## Related Decision

[Adaptive context observation reuse](../../ADR.md): compare independent observations, bounded batch, and process-local read session for STAGED context responses.

## Hypothesis

**Tentative:** bounded batch can reduce T2/T3 to two full observations without adding session lifecycle. A session may be faster if exact `ClientPrecondition` verification can avoid repeated Document decode and validation. Neither candidate is accepted before correctness and qualification results.

## Questions

Can the production precondition algorithm be checked under the real `WorktreeCoordinator` Ready boundary without a full decode? Do CURRENT, BATCH, and SESSION produce equivalent observation-bound, Scope-filtered, bounded payloads? Which candidate qualifies on the same L/S/C shapes, including failure behavior and lock lifetime?

## Prototype Scope

Reuse the disposable L/S/C fixtures of [shard-shape Evidence](../../../git-canonical-sharding/spikes/shard-merge-benchmark/artifacts/observation-shape-analysis.md), each with 10,002 Layers and the same semantic base. Use production `ProjectContextService` projections through a fixed in-memory `ProjectRepository` after real observations. BATCH performs summary/layer/resources from observation S0 and the caller-chosen detail from a second observation S1; assert at most two full observations. SESSION starts with one real S0 and, before each follow-up, verifies the current production `ClientPrecondition` under the real coordinator Ready gate; assert one initial observation and one verifier call per follow-up. The verifier may use a `#if DEBUG` or test-internal seam but must call the production token algorithm rather than copy it. No lock spans requests or response transport. CURRENT uses the production one-shot flow as baseline.

Correctness cases are precommitted:

1. Unchanged source: follow-up response matches production CURRENT payload and S0 observation.
2. Coordinated semantic mutation: old S0 rejected before cached payload; mutation remains `ProjectService.mutate(... expectedState: S0)`.
3. Same revision, different state after managed Git transition: reject S0.
4. Coordinated A → B → A bytes: old S0 stays invalid through epoch.
5. Managed Git / merge / migration pending gate: no cached response.
6. Missing client epoch: fail closed; do not revive S0.
7. Corrupt client epoch: fail closed.
8. Agent profile Canonical change: reject S0.
9. Detectable external Canonical edit: reject S0. Unobserved raw external A → B → A is outside the writer Product Contract.
10. T1/T2/T3 and negative Scope task: same semantic payload, order, bounds, and `ContextObservation` as CURRENT.

The verifier may complete, release the lock, and then a writer may transition before response transport. The response remains labeled S0 and subsequent mutation must reject S0. This matches existing observation semantics; it does not promise current-at-send-time.

## Out of Scope

Production batch/session/CLI API, persistent cache, cross-process sharing, disk serialization of sessions, daemon or transport design, session ID encoding, sharding or partial loading, DocumentValidator optimization, weaker token semantics, long-lived worktree lock, static overfetch of up to 32 details, AI LLM task success, AI total tokens, and model cost. Process restart destroys the test session and requires a new full observation.

## Measurements

For each L/S/C shape: CURRENT one-shot equivalent 10 runs/task; BATCH and SESSION 20 runs/task; verifier alone 50 runs. T2 is the primary metric, T3 confirmation, T1 two-response control. Record median/min/max, payload bytes and ratio to CURRENT, full-observation count, freshness-verification count, process/simulated-process count, same-observation/payload/Scope/stale outcomes, lock-held-between-requests, and restart reuse. Debug warm-local measurement only; no p95/SLA or production CLI latency claim. The minimal CLI floor from the earlier observation-cost profile is contextual only.

## Success Criteria

All correctness cases pass: zero false current, Scope violation, mixed observation, or accepted stale mutation. BATCH retains at most two full T2/T3 observations and payload at most 110% of CURRENT staged bytes; its median is at most 60% of CURRENT for T2 in every L/S/C shape. SESSION has one initial full observation, a production-equivalent verifier before every follow-up, no lock between requests, payload at most 110%, and median at most 40% of CURRENT for T2 in every shape.

Precommitted selection rule: if exactly one qualifies, it is the decision candidate. If both qualify, prefer BATCH for its smaller lifecycle/failure surface unless SESSION median is at most 75% of BATCH median for T2 in **every** shape and introduces zero additional correctness failure modes. If neither qualifies, CURRENT remains the candidate. These percentages route this decision; they are not Product SLAs and must not change after Evidence.

## Failure Criteria

Any correctness hard-gate failure disqualifies that candidate even if it is faster. SESSION fails if exact verification needs a full Document decode/validation or requires a lock while awaiting a request. BATCH fails if its apparent one-observation gain requires resource-detail overfetch. Neither candidate may weaken mutation preconditions, Scope rules, or the current unknown-state fail-closed behavior. A threshold changed after observing results invalidates the decision Evidence.

## Result

[Candidate comparison and conditions](artifacts/candidate-comparison.md) and [raw matrix](artifacts/candidate-matrix.json) record the L/S/C results. CURRENT same-process T2 medians were 440.202/485.699/503.137 ms; BATCH 219.911/242.451/257.947 ms; SESSION 117.113/142.161/156.343 ms. Stable verifier median was 2.288/6.824/7.047 ms. All measured payloads and ContextObservations matched production CURRENT; the precommitted stale, pending, epoch, profile, external-edit, and Scope cases rejected or matched as required. An initial comparison using current one-shot CLI as denominator mixed process startup with candidates; the final matrix adds same-process CURRENT service timings and uses those for qualification, retaining CLI timings separately.

## Conclusion

Both reuse candidates qualify under the precommitted gates. SESSION is at most 75% of BATCH T2 median in all shapes and had zero additional correctness failures in the tested cases, so the rule selects **SESSION as Decision candidate**. This is test-only Evidence, not a production API or completed concurrency/power-loss proof. The ADR remains `Spike Required` until its separate Decision commit.

## Artifacts

- [Candidate matrix](artifacts/candidate-matrix.json)
- [Candidate comparison](artifacts/candidate-comparison.md)
