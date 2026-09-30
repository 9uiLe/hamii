# Adaptive context observation reuse

## Context

Production one-shot STAGED AI context uses one `CanonicalRepository.observe()` per response. The [observation-shape phase](../git-canonical-sharding/spikes/shard-merge-benchmark/artifacts/observation-shape-analysis.md) measured a single 10k-Layer observation at 109–122 ms across L/S/C shapes, while four-response T2 CLI workflows took 490–551 ms. A test-only one-observation candidate was faster, but it did not establish a safe production reuse contract. The sharding ADR remains `Spike Required`; this ADR concerns the number and freshness of observations used for context responses.

## Decision to Make

When supplying multiple STAGED semantic context responses, should hamii keep one full Canonical observation per response, offer a bounded batch from one validated observation, or hold a process-local read session with lightweight verification? If reuse is chosen, what minimum freshness contract prevents a stale or unknown Canonical state from being treated as current?

## Constraints

`ClientPrecondition` retains its [decided meaning](../canonical-state-precondition/ADR.md): an opaque exact client observation base; `DocumentRevision` remains ordering only. One worktree is one coordinated writer domain. Mutation always revalidates through `ProjectService` with the client's expected state. Context Scope and availability use existing production services. A response may become stale after its observation; no lock is held through AI thinking, human review, next-request wait, or response transport. Unknown, pending, corrupt, and mismatched states fail closed. Raw uncoordinated A → B → A remains outside the existing Product Contract. No Index-based availability, Canonical sharding change, partial reader, persistent daemon, visual context, LLM protocol, or CLI taxonomy decision belongs here.

## Options

- **CURRENT:** each response performs a full `observe()`; T2/T3 require four observations.
- **BOUNDED BATCH:** a request projects multiple bounded responses from one validated `ProjectObservation`, then discards it. Adaptive T2/T3 use one summary/layer/resources batch, followed by a separate detail observation after the caller chooses a resource; no mini query language, output reference syntax, or detail overfetch.
- **PROCESS-LOCAL READ SESSION:** retain one immutable validated `ProjectObservation` in memory. Before each follow-up, acquire the real coordinated Ready boundary and verify the current `ClientPrecondition` using the production algorithm. A match permits projection from cached data; mismatch, pending, corruption, or unknown invalidates the session before payload generation. Restart discards the session.

## Current Hypothesis

Before the Spike, bounded batch appeared to have the smaller failure surface, while a process-local session needed to justify its lifecycle with exact freshness verification and material savings across all measured shapes. The Decision below supersedes that hypothesis.

## Decision

Adopt a **process-local read session** as the production implementation target for multiple STAGED semantic context responses. Retain one immutable, fully validated Canonical observation S0. Before every follow-up response, reacquire the coordinated worktree boundary, recover the Canonical journal, require Ready state, and compare the current `ClientPrecondition` with S0 using the existing production algorithm. Only an exact match permits projection from S0. Mismatch, pending publication, missing or corrupt coordination state, or failed verification invalidates the session and returns a structured failure before producing a payload. A process restart discards the session. No lock spans AI thinking, transport, or time between requests. Every response identifies S0 as its observation; mutations continue to use `ProjectService` with S0 as `expectedState` and revalidate there.

Do not add a second production bounded-batch path. The independent-observation path remains available for one-shot reads; the session contract is implemented and validated. A context response can become stale after verification; its state token is a mutation precondition, not a promise that the worktree remains unchanged.

The [adaptive-read Spike](spikes/adaptive-read/SPIKE.md) met the precommitted correctness and timing criteria in the tested L/S/C shapes. Same-process T2 service medians were 440.202/485.699/503.137 ms for CURRENT, 219.911/242.451/257.947 ms for BATCH, and 117.113/142.161/156.343 ms for SESSION. SESSION/BATCH ratios were 0.533/0.586/0.606. T1 SESSION was slightly slower than BATCH, so the decision applies to multi-response reuse. These are test-only prototype measurements, not production performance or AI-token savings. Separate CLI timings are not used as the qualification denominator.

## Unknowns

No unresolved implementation or decision remains within the observation-reuse boundary. Canonical sharding belongs to `git-canonical-sharding`, power-loss durability to `canonical-power-loss-durability`, and general CLI taxonomy to `cli-command-taxonomy`. AI total tokens, LLM task success, model cost and cold-cache/general workload performance remain unmeasured facts in the performance documentation; they are not implementation blockers for this decision. The original Spike measurements remain test-only evidence.

## Implementation Progress

`ProjectContextReadSession` holds one immutable validated S0 and generates its initial summary at start. Each follow-up verifies S0 under the coordinated Ready boundary, then calls the same pure projection as `ProjectContextService`. `CanonicalRepository.verifyCurrent` performs transaction recovery and the existing exact client-precondition calculation without a full Document decode. Failure permanently invalidates the session. The one-shot CLI keeps independent observations. `query context session --json` connects the same Application core to bounded NDJSON input and structured output in one OS process; it has no registry or persistent cache. Real-process tests cover one-shot payload equivalence, usage recovery, EOF/close, separate-process mutations, equal-revision managed switch, pending gates, epoch corruption and restart. Focused production regression tests cover payload equivalence, observation counts, coordinated transitions, pending gates, epoch and generation corruption, journal recovery, and mutation revalidation. The transport commit `2d7d7815238511ba93018d0e30ebc39900b61de0` passed exact-SHA Verify with 14 checks and 291 tests (62 intentional skips, zero failures). The [Release comparison](../../docs/context-session-performance.md) uses ten paired trials per L/S/C shape and T1/T2/T3, with equivalent raw response bytes. The final-harness T2/T3 ratios are 0.265–0.295 (initial retained run: 0.264–0.295), meeting the precommitted 0.70 ceiling in all shapes. The measurement commit passed exact-SHA Verify. Closure review confirms implementation and validation are complete; the ADR remains in the queue only until this evidence commit passes CI and a later commit removes it.

## Required Evidence

- [Adaptive read Spike](spikes/adaptive-read/SPIKE.md), [comparison](spikes/adaptive-read/artifacts/candidate-comparison.md), and [raw matrix](spikes/adaptive-read/artifacts/candidate-matrix.json): precommitted CURRENT/BATCH/SESSION correctness and timing on the same L/S/C fixtures as the sharding observation phase. Evidence commit `8cd17d0a8ebd620d806949cdd2597e5cfcbd58ec` passed exact-SHA CI run `36583193339`. The prototypes are not production APIs.

## Decision Criteria

False current, Scope violations, mixed `ContextObservation`, or stale mutation acceptance disqualify a candidate regardless of speed. Apply the Spike's precommitted payload, observation-count, median-ratio, and complexity thresholds without changing them after results. If neither reuse candidate qualifies, retain independent observations. A decision must name its freshness guarantee and failure behavior before implementation.

SESSION qualified in all measured shapes, with no additional failure in the tested correctness matrix and T2 median at most 75% of BATCH. The Spike alone does not prove arbitrary external-writer safety, process restart behavior, production end-to-end latency, or AI-token reduction. Production lifecycle and Release retrieval validation are recorded below; arbitrary external writers and unmeasured AI metrics are not promoted to supported guarantees.

## Release Transport Acceptance Criteria (before measurement)

Compare CURRENT independent one-shot processes against SESSION one process + NDJSON requests using the same Release executable, local environment and L/S/C 10,002-Layer fixtures. Run ten paired iterations per shape and task T1/T2/T3, alternating order. Time from process launch to the last required context response; session close and fixture preparation are excluded. For both T2 and T3 in all three shapes, SESSION median must be at most 70% of CURRENT median. T1 is reported without a threshold. This is a comparison criterion, not a Product SLA, and must not change after measurements. Require identical semantic payloads and observations, one full session observation, one freshness verification per follow-up, and unchanged correctness gates. Report median/min/max and raw samples; do not claim p95 from ten trials. AI total tokens, LLM task success and model cost remain unmeasured.

## Closure Review

The decision, required research/Spike, production core, external CLI entry point, close/EOF/restart lifecycle, structured invalidation, correctness tests and scoped Release validation are complete.

| Evidence | Commit | Exact-SHA verification |
| --- | --- | --- |
| Decision | `c250c479dacd3f8cce74031d296e60af4d08a472` | Decision preserved in Git history |
| Required Spike | `8cd17d0a8ebd620d806949cdd2597e5cfcbd58ec` | [Verify success](https://github.com/9uiLe/hamii/actions/runs/36583193339) |
| Production session core | `37685851896c0980066b5abcddc9f8ffbd9f9de4` | [Verify success](https://github.com/9uiLe/hamii/actions/runs/36593520519) |
| CLI transport | `2d7d7815238511ba93018d0e30ebc39900b61de0` | [Verify success](https://github.com/9uiLe/hamii/actions/runs/36651548078) |
| Release measurement | `e8c206e81f3a8cf11322efb302a69d099142825d` | [Verify success](https://github.com/9uiLe/hamii/actions/runs/36653624988) |

Transport and measurement Verify runs each reconcile 291 tests, 62 intentional skips and zero failures with all 14 checks passed. All 180 measured pairs across the two retained rounds have equivalent raw responses; both rounds meet the unchanged T2/T3 median criterion in every shape.

Current ownership is independent of this ADR: [README](../../README.md), [architecture](../../docs/final-architecture.md), [implementation status](../../docs/implementation-status.md), [CLI contract](../../docs/context-session.md) and [Release comparison](../../docs/context-session-performance.md) describe validated S0, exact follow-up verification, terminal/nonterminal errors, no mutation authority, no idle lock, restart, no persistent session state, one-shot reads and measurement limits. The implementation status lists the transport/lifecycle as implemented.

No in-boundary follow-up remains. This closure does not claim power-loss durability, arbitrary external-writer safety, AI token savings, model cost or general performance guarantees. The separate ADRs named under Unknowns retain their own decisions. Commit this review, verify its exact SHA, and delete this directory only in a later commit; do not archive it in the working tree.

## Status

Implementation Required
