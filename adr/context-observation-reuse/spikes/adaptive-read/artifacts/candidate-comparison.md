# CURRENT, bounded batch, and process-local read session

## Reproduction and boundary

[Raw candidate matrix](candidate-matrix.json) was produced by `python3 scripts/measure-context-observation-reuse.py --output adr/context-observation-reuse/spikes/adaptive-read/artifacts/candidate-matrix.json`. The script reuses the L/S/C 10,002-Layer fixture builders from the [shard-shape phase](../../../../git-canonical-sharding/spikes/shard-merge-benchmark/artifacts/observation-shape-analysis.md). Every shape keeps the same Scope hierarchy, selected Screen/Layer, available and unavailable Components, Token, AppSurface, Target, and capability declaration. Destructive correctness cases use separate clones of the common semantic base.

All timings use debug builds on the local warm filesystem. Each task/shape has 10 same-process CURRENT service samples, 10 current one-shot CLI workflow samples, 20 BATCH samples, and 20 SESSION samples. The lightweight verifier has 50 samples per shape. Raw JSON contains every sample, min/max, payload bytes, count, platform, and Swift version. AI total tokens, LLM task success, and model cost were not measured. No p95 or Product SLA is claimed.

CURRENT service timing performs the normal 2 or 4 `ProjectContextService` calls against a real `CanonicalRepository` in one test process. BATCH and SESSION use the **same production projections** against fixed in-memory `ProjectObservation`s; BATCH obtains two real observations for T2/T3, and SESSION obtains one and verifies the production ClientPrecondition under `WorktreeCoordinator` before each follow-up. All candidates encode their responses inside the timed operation. One-shot CLI results are recorded separately and are **not** the denominator for qualification, so process startup does not inflate the candidate ratios.

| Median ms | L | S | C |
| --- | ---: | ---: | ---: |
| Verifier alone | 2.288 | 6.824 | 7.047 |
| T1 CURRENT service / BATCH / SESSION | 220.151 / 109.962 / 112.259 | 242.241 / 121.295 / 127.910 | 247.204 / 122.676 / 129.674 |
| T2 CURRENT service / BATCH / SESSION | 440.202 / 219.911 / 117.113 | 485.699 / 242.451 / 142.161 | 503.137 / 257.947 / 156.343 |
| T3 CURRENT service / BATCH / SESSION | 441.399 / 220.458 / 117.175 | 485.623 / 242.656 / 142.030 | 491.505 / 245.483 / 144.004 |
| T2 current one-shot CLI (separate) | 490.646 | 535.187 | 553.226 |
| T2 BATCH / CURRENT service | 0.500 | 0.499 | 0.513 |
| T2 SESSION / CURRENT service | 0.266 | 0.293 | 0.311 |
| T2 SESSION / BATCH | 0.533 | 0.586 | 0.606 |

For T2/T3 the measured full-observation counts are CURRENT 4, BATCH 2, SESSION 1. SESSION performs three lightweight verifications; T1 uses one verification. Semantic context JSON payload bytes are exactly equal among CURRENT, BATCH, and SESSION for every shape/task (T2: 2,777/2,777/2,776 bytes across L/S/C). The candidates use one XCTest process and simulate request boundaries; no production batch/session CLI, daemon, transport, or measured production CLI speedup exists.

## Correctness observations

The test-only verifier acquires the real worktree lock, performs transaction recovery and Ready checks, invokes existing generation recovery, then calls the same production `clientPreconditionUnlocked()` path used by `observe()`. On a stable generation it does not decode or validate the full Document. A missing/pending generation may trigger recovery; those paths were not timed as steady-state verifications. The verifier is `#if DEBUG`, and normal `observe()`, save, mutation, token algorithm, and Scope rules were not changed.

The unchanged-source session returned the same `ContextObservation` and payload as production CURRENT. A semantic mutation while the session object existed succeeded, showing no lock was held between requests; the old session then rejected before payload and the old token failed `ProjectService.mutate`. A two-observation batch rejected a detail request when Canonical state changed between resource list and detail. The session rejected a same-revision managed branch switch and a coordinated A → B → A return to the original text. Managed Git, merge publication, and migration publication pending markers each rejected cached reads. Missing or corrupt client epochs, an Agent profile edit, and a detectable external Canonical edit also rejected and invalidated the session. The negative sibling-Scope Component list remained empty and matched production. No cached Document is serialized or reusable after process restart; this is a test-only process-local object, not a demonstrated OS restart protocol. Raw uncoordinated A → B → A is outside the existing writer Product Contract.

The test suite found zero false-current returns, Scope violations, mixed observations, or accepted stale mutations in these cases. This is not an exhaustive concurrency or power-loss proof. The verifier releases its lock before projection/response transport; a later writer can make an S0 response stale, and mutation still revalidates S0 through `ProjectService`.

## Precommitted qualification

BATCH meets its correctness, two-observation, equal-payload, and ≤60%-of-CURRENT T2 thresholds in L/S/C. SESSION meets its correctness, one-observation plus three-verification, equal-payload, no-inter-request-lock, and ≤40%-of-CURRENT T2 thresholds. SESSION T2 median is ≤75% of BATCH in every shape (0.533/0.586/0.606), and no additional correctness failure was observed. The precommitted selection rule therefore names **SESSION as the Decision candidate**. T1 SESSION is slightly slower than BATCH because the verifier adds work; the choice is driven by T2 with T3 confirmation, as precommitted.

This result does not select a production session ID, transport, CLI shape, persistence model, or release performance target. Session correctness under all writer races, restart, and power loss still needs production implementation validation if the ADR adopts the candidate. The ADR remains `Spike Required` until a separate Decision commit.
