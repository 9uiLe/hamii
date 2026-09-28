# Git CanonicalRevision observation protocol

## Context

`GitCanonicalRevisionCalculator.current(at:)` uses four real Git executions: an initial `status --porcelain=v2 --branch`, `ls-files -v`, `check-attr filter`, and a final status comparison. On 2026-09-28, the measured 5000 Component clean fixture had oracle p50 / p95 of 383.23 / 383.32 ms; the four Git executions each took roughly 80–100 ms. [Measurement conditions and raw samples](../../docs/git-canonical-revision-performance.md) are local mechanism evidence, not a Product SLA. Index Query must still fail closed when Canonical freshness cannot be proven.

This decision depends on the coordinated writer domain defined by [External Git Write Coordination](../git-external-write-coordination/ADR.md). That ADR defines who may write; this ADR concerns which Git and working-tree evidence a freshness observation uses. Raw Git and external editors in the same worktree remain outside the safe collaboration path. `CanonicalRevision` itself is a separate abstraction from the algorithm used here.

## Decision to Make

Can the current fail-closed evidence for Canonical working-tree identity and unsafe Git metadata be gathered with fewer than four **real Git command executions** per logical observation, while preserving the tested revision, rejection, and race semantics?

## Constraints

- Preserve the current production calculator and stale Index rejection until a candidate passes correctness and performance gates.
- A shell or wrapper that invokes four Git children still counts as four Git executions.
- Preserve the current revision for clean, dirty, untracked, deleted, and renamed Canonical JSON in the Spike's parity matrix. This does not settle the long-term CanonicalRevision algorithm or false positive invalidation on unrelated commits.
- Hidden `assume-unchanged` / `skip-worktree` state and active clean filters cannot authorize current. Failure, malformed output, unexpected encoding, or uncertain source must fail closed.
- The final observation fence must retain the branch / working-tree races actually rejected by the current status comparison. `git status #2` is the current implementation, not a permanent product command requirement. It is not a fence over every Git metadata source.
- A repeated digest, metadata-only check, or watcher silence does not prove a coherent multi-file snapshot under arbitrary external writers.
- This ADR neither expands the coordinated writer contract nor chooses an Index recovery strategy. [Incremental Index Recovery](../incremental-index-recovery/ADR.md) remains separate.

## Options

1. Retain the four Git executions and current parser as the safe baseline.
2. Use existing Git commands, plumbing, or output modes to consolidate equivalent evidence into fewer real Git executions.
3. Obtain selected Git metadata in-process, with explicit risk for Git semantics, compatibility, and dependency maintenance.

A persistent cache, watcher, or `CanonicalGeneration` alone is not a positive freshness proof in this decision. Those would require a different invalidation and writer guarantee argument.

## Current Hypothesis

The four-execution protocol is the smallest currently validated implementation for the chosen E1–E4 evidence classes on the installed Git. This is a bounded, version-specific conclusion, not a claim that four executions are mathematically minimal for all Git implementations.

## Unknowns

- Future Git releases or an in-process implementation may expose a different capability and cost balance; that is outside this decision's installed, documented one-shot CLI boundary.
- The wider Index end-to-end latency and incremental recovery strategy remain in their own ADRs. Retaining this oracle does not set a Product SLA.

## Required Evidence

The [Git evidence consolidation Spike](spikes/git-evidence-consolidation/SPIKE.md) mapped E1–E4, measured the actual calculator's after-E2/E3 metadata blind windows, and rejected a test-only three-call `ls-files -v --eol` candidate because it accepted a pre-existing clean filter. The [CLI capability closure Spike](spikes/cli-capability-closure/SPIKE.md) classified every evidence-class pair using official Git documentation and the production `/usr/bin/git` 2.54.0 outputs. It found no documented one-shot command that provides a complete pair while preserving distinct E1/E4 times. Both prerequisite Verify runs and local checks passed. These are bounded observations, not a proof about all possible Git implementations.

## Decision Criteria

A candidate can advance only if it uses fewer than four real Git executions; matches production revision for all listed normal states; rejects hidden flags and active filters when its relevant evidence is captured; fails closed on malformed, uncertain, or contradictory observed evidence; rejects the branch/working-tree mixed observations that production rejects; documents rather than claims closure of known metadata blind windows; infers no arbitrary external-writer atomicity; and shows an observed total wall-time benefit without disproportionate complexity. The tested three-call candidate failed the filter gate. The bounded documented-CLI survey found no other complete pairwise consolidation. In-process Git metadata reading has substantial semantic and maintenance cost without sufficient current evidence of Product benefit. No fixed latency threshold or Product SLA is set by this ADR.

## Decision

Retain the current four-real-Git-execution observation protocol. It is the smallest currently validated protocol for E1 initial branch/worktree status, E2 tracked paths and hidden index flags, E3 filter attributes, and E4 a later branch/worktree status fence. The tested three-call consolidation loses clean-filter rejection, and the documented one-shot Git CLI surface on production's Apple Git 2.54.0 supplies no confirmed baseline-equivalent three-call composition. Reimplementing Git metadata semantics in-process is not justified by the available correctness, latency, and Product-value evidence.

This decision preserves the coordinated writer Product Contract and the stale Index fail-closed behavior. It does not claim that four calls are theoretically minimal forever or that the oracle atomically observes arbitrary external writers. Future changes to Git capabilities or measured Product latency may justify a new, narrowly scoped decision.

## Status

Ready for Decision

Decision recorded; final Verify and ADR deletion are pending. The production implementation already exists, so no implementation work is implied by this transient queue status.
