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
- The final observation fence must reject an observed mixed source. `git status #2` is the current implementation, not a permanent product command requirement. A candidate cannot simply remove it without equivalent evidence.
- A repeated digest, metadata-only check, or watcher silence does not prove a coherent multi-file snapshot under arbitrary external writers.
- This ADR neither expands the coordinated writer contract nor chooses an Index recovery strategy. [Incremental Index Recovery](../incremental-index-recovery/ADR.md) remains separate.

## Options

1. Retain the four Git executions and current parser as the safe baseline.
2. Use existing Git commands, plumbing, or output modes to consolidate equivalent evidence into fewer real Git executions.
3. Obtain selected Git metadata in-process, with explicit risk for Git semantics, compatibility, and dependency maintenance.

A persistent cache, watcher, or `CanonicalGeneration` alone is not a positive freshness proof in this decision. Those would require a different invalidation and writer guarantee argument.

## Current Hypothesis

Option 2 may reduce wall time, but no available command combination has yet been shown to cover the tracked flags, filter attributes, initial state, and final observation fence. Test-only exploration should identify which evidence can be combined before any production rewrite. Option 3 is not the preferred first candidate because it may reimplement Git semantics.

## Unknowns

- Whether one real Git invocation can report more than one of the required evidence classes without changing semantics.
- Whether a fewer-process candidate can preserve the current `CanonicalRevision` and all rejection cases.
- What the existing final status comparison does and does not detect for metadata changes made after the flag or filter check.
- Whether a candidate can reject branch switch, raw Canonical edit, hidden flag change, and filter/config change at each relevant interleaving point.
- Whether fewer calls yield lower total wall time across small, large, mixed, dirty, and untracked fixtures.

## Required Evidence

The [Git evidence consolidation Spike](spikes/git-evidence-consolidation/SPIKE.md) first maps the current four calls to E1 initial worktree observation, E2 tracked paths/flags, E3 filter attributes, and E4 final worktree observation. It then tests one test-only fewer-process candidate against production results, including clean 1/1000/5000/mixed, dirty, untracked, deleted, and renamed JSON; hidden flags/filter; malformed/error outcomes; and branch, raw edit, hidden metadata, and filter/config races. Record actual Git execution count, per-call and total p50/p95, tracked/changed counts, and working bytes hashed. Distinguish confirmed behavior from inferred guarantees.

## Decision Criteria

A candidate can advance only if it uses fewer than four real Git executions; matches production revision for all listed normal states; rejects hidden flags, filters, malformed output and command failures; does not return positive current for the race matrix; and shows an observed total wall-time benefit without disproportionate complexity. A missing gate keeps the four-call production baseline. No fixed latency threshold or Product SLA is set by this ADR.

## Status

Spike Required
