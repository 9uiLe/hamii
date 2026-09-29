# Adaptive context observation reuse

## Context

Production STAGED AI context uses one `CanonicalRepository.observe()` per response. The [observation-shape phase](../git-canonical-sharding/spikes/shard-merge-benchmark/artifacts/observation-shape-analysis.md) measured a single 10k-Layer observation at 109–122 ms across L/S/C shapes, while four-response T2 CLI workflows took 490–551 ms. A test-only one-observation candidate was faster, but it did not establish a safe production reuse contract. The sharding ADR remains `Spike Required`; this ADR concerns the number and freshness of observations used for context responses.

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

Do not add a second production bounded-batch path. The current independent-observation path remains the safe production behavior until the session contract is implemented and validated. A context response can become stale after verification; its state token is a mutation precondition, not a promise that the worktree remains unchanged.

The [adaptive-read Spike](spikes/adaptive-read/SPIKE.md) met the precommitted correctness and timing criteria in the tested L/S/C shapes. Same-process T2 service medians were 440.202/485.699/503.137 ms for CURRENT, 219.911/242.451/257.947 ms for BATCH, and 117.113/142.161/156.343 ms for SESSION. SESSION/BATCH ratios were 0.533/0.586/0.606. T1 SESSION was slightly slower than BATCH, so the decision applies to multi-response reuse. These are test-only prototype measurements, not production performance or AI-token savings. Separate CLI timings are not used as the qualification denominator.

## Unknowns

Production session lifetime and memory bounds, Application Service and CLI entry points, multi-process contention, process restart behavior, release end-to-end performance, and structured invalidation/resync UX remain implementation and validation work. The test-only verifier is not a production API. Power-loss durability remains with its separate ADR. Session ID encoding and CLI command spelling are implementation details unless they expose a new decision boundary.

## Required Evidence

- [Adaptive read Spike](spikes/adaptive-read/SPIKE.md), [comparison](spikes/adaptive-read/artifacts/candidate-comparison.md), and [raw matrix](spikes/adaptive-read/artifacts/candidate-matrix.json): precommitted CURRENT/BATCH/SESSION correctness and timing on the same L/S/C fixtures as the sharding observation phase. Evidence commit `8cd17d0a8ebd620d806949cdd2597e5cfcbd58ec` passed exact-SHA CI run `36583193339`. The prototypes are not production APIs.

## Decision Criteria

False current, Scope violations, mixed `ContextObservation`, or stale mutation acceptance disqualify a candidate regardless of speed. Apply the Spike's precommitted payload, observation-count, median-ratio, and complexity thresholds without changing them after results. If neither reuse candidate qualifies, retain independent observations. A decision must name its freshness guarantee and failure behavior before implementation.

SESSION qualified in all measured shapes, with no additional failure in the tested correctness matrix and T2 median at most 75% of BATCH. Production adoption still requires the implementation and validation listed above; the Spike does not prove arbitrary external-writer safety, OS restart recovery, production end-to-end latency, or AI-token reduction.

## Status

Implementation Required
