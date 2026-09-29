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

**Tentative:** bounded batch has the smaller failure surface because it holds no state between requests. A process-local session may justify its lifecycle only if the exact freshness verifier is both correct and materially faster on all measured shapes. Neither is a production decision yet.

## Unknowns

Whether a lightweight verifier can reuse the exact production precondition algorithm without a full Document decode/validation; its behavior under coordinated and detectable external transitions; candidate payload/Scope equivalence; L/S/C timing and byte costs; the additional failure modes of a process-local session. Session ID encoding, transport, and CLI command spelling are not decided here.

## Required Evidence

- [Adaptive read Spike](spikes/adaptive-read/SPIKE.md): precommitted CURRENT/BATCH/SESSION correctness and timing matrix on the same L/S/C fixtures as the sharding observation phase. Its prototypes are not production APIs.

## Decision Criteria

False current, Scope violations, mixed `ContextObservation`, or stale mutation acceptance disqualify a candidate regardless of speed. Apply the Spike's precommitted payload, observation-count, median-ratio, and complexity thresholds without changing them after results. If neither reuse candidate qualifies, retain independent observations. A decision must name its freshness guarantee and failure behavior before implementation.

## Status

Spike Required
