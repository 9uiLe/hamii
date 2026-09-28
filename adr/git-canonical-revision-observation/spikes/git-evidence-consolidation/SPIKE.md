# Git evidence consolidation

## Related Decision

[Git CanonicalRevision observation protocol](../../ADR.md): can the current evidence be gathered with fewer real Git executions while remaining fail closed?

## Hypothesis

Some E1–E4 evidence may be obtainable from one Git invocation. A candidate must preserve the current revision and rejection semantics and retain an effective final observation fence.

## Questions

- What exact evidence do `status #1`, `ls-files -v`, `check-attr filter`, and `status #2` each contribute?
- Which existing Git command/output modes can combine that evidence, and which cannot?
- Does the current final status comparison detect changes to tracked flags or filter configuration made after their own checks?
- Can a candidate use fewer real Git executions and pass normal-state, unsafe-metadata, error, and race matrices?
- Is its total wall time lower under comparable fixture conditions?

## Prototype Scope

Map E1–E4 using the installed Git and official Git command documentation. Prototype at most one fewer-process provider in test-only code. Compare it with `GitCanonicalRevisionCalculator.current(at:)` on real temporary Git worktrees. Use deterministic barriers for branch switch, raw Canonical edit, hidden flag change, and filter/config change. Count actual Git invocations, not wrapper processes.

## Out of Scope

Production calculator replacement, cache/invalidation design, persistent watcher, `CanonicalGeneration` as Git oracle replacement, production libgit2 adoption, raw external writer collaboration guarantee, Index incremental recovery, ClientPrecondition integration, and a new CanonicalRevision encoding.

## Measurements

For 1/1000/5000 Component clean, mixed semantic clean, dirty tracked, and untracked Canonical shard: 5–10 runs per fixture; actual Git execution count, per invocation and total p50/p95, tracked/changed paths, working bytes hashed. Compare normal-state revisions and failure categories independently from timing.

## Success Criteria

A candidate uses fewer than four real Git executions, matches the production revision for clean/dirty/untracked/deleted/renamed Canonical JSON, rejects hidden flags and filters, fails closed on representative malformed/error inputs, rejects all four race classes, and reduces measured total wall time. A current baseline limitation found by the Spike must be reported explicitly rather than silently treated as a candidate requirement that production already satisfies.

## Failure Criteria

Any false current verdict, silent approximation, missing final fence, untested actual Git child count, changed production behavior, or performance claim from a wrapper that still executes four Git children. Inconclusive evidence leaves the ADR `Spike Required`.

## Result

Pending investigation.

## Conclusion

Pending evidence; the production four-execution calculator remains unchanged.

## Artifacts

Create `artifacts/` only for focused reproducible evidence and small raw measurements needed to review the result.
