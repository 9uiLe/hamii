# Git evidence consolidation

## Related Decision

[Git CanonicalRevision observation protocol](../../ADR.md): can the current evidence be gathered with fewer real Git executions while remaining fail closed?

## Hypothesis

Some E1–E4 evidence may be obtainable from one Git invocation. A candidate must preserve the current revision and rejection semantics and retain an effective final observation fence.

## Questions

- What exact evidence do `status #1`, `ls-files -v`, `check-attr filter`, and `status #2` each contribute?
- Which existing Git command/output modes can combine that evidence, and which cannot?
- Does the current final status comparison detect changes to tracked flags or filter configuration made after their own checks? What does the actual calculator return under test-only hooks?
- Can a candidate use fewer real Git executions and pass normal-state, unsafe-metadata, error, and race matrices?
- Is its total wall time lower under comparable fixture conditions?

## Prototype Scope

Map E1–E4 using the installed Git and official Git command documentation. Characterize command-output interleavings, then use DEBUG-only hooks after E2 and E3 to observe the actual calculator outcome without asserting it in advance. Prototype at most one fewer-process provider in test-only code. Compare it with `GitCanonicalRevisionCalculator.current(at:)` on real temporary Git worktrees. Use deterministic barriers for branch switch and raw Canonical edit; classify hidden flag / filter changes after their checks as defense-in-depth characterization, not automatic candidate failures. Count actual Git invocations, not wrapper processes.

## Out of Scope

Production calculator replacement, cache/invalidation design, persistent watcher, `CanonicalGeneration` as Git oracle replacement, production libgit2 adoption, raw external writer collaboration guarantee, Index incremental recovery, ClientPrecondition integration, and a new CanonicalRevision encoding.

## Measurements

For 1/1000/5000 Component clean, mixed semantic clean, dirty tracked, and untracked Canonical shard: 5–10 runs per fixture; actual Git execution count, per invocation and total p50/p95, tracked/changed paths, working bytes hashed. Compare normal-state revisions and failure categories independently from timing.

## Success Criteria

A candidate uses fewer than four real Git executions, matches the production revision for clean/dirty/untracked/deleted/renamed Canonical JSON, rejects hidden flags and filters present when its respective evidence is observed, fails closed on representative malformed/error inputs and observed contradictions, rejects branch/working-tree races that production rejects, and reduces measured total wall time. Known metadata blind windows are documented and not widened without evidence; stronger rejection is recorded separately. A current baseline limitation must not be silently treated as a guarantee production already satisfies.

## Failure Criteria

Any false current verdict within the coordinated writer guarantee or for evidence the candidate actually observes, silent approximation, regression of the production branch/working-tree fence, untested actual Git child count, changed production behavior, or performance claim from a wrapper that still executes four Git children. Noncoordinated metadata changes after their evidence was captured are characterized separately. Inconclusive evidence leaves the ADR `Spike Required`.

## Result

### E1–E4 baseline evidence map

- **E1 — initial `status --porcelain=v2 --branch -z`:** captures the branch HEAD OID and Git-reported tracked, untracked, ignored, deleted, or renamed Canonical path status at the first observation. The calculator appends the OID and exact working bytes for reported changed paths to its revision hash. [Git status documentation](https://git-scm.com/docs/git-status) defines porcelain v2's branch and change records.
- **E2 — `ls-files -v -z`:** enumerates tracked Canonical paths and flag tags. The current parser accepts only ordinary `H ` records; a hidden flag changes that tag and causes `unverifiableSource` when present at E2. [Git ls-files documentation](https://git-scm.com/docs/git-ls-files) describes `-v` flags, and [Git update-index documentation](https://git-scm.com/docs/git-update-index) explains why assume-unchanged / skip-worktree can hide changes from ordinary status checks.
- **E3 — `check-attr -z --stdin filter`:** obtains the `filter` attribute for each E2 path. A value other than `unspecified` or `unset` causes `unverifiableSource` when present at E3. [Git check-attr documentation](https://git-scm.com/docs/git-check-attr) defines the path/attribute/value result format.
- **E4 — final `status` equality:** rejects differences in this Git status output between E1 and E4. It does not explicitly re-read E2 flags or E3 attributes.

### Confirmed command-output interleavings

Using Apple Git 2.54.0 in a temporary clean worktree, [the focused probe](artifacts/baseline_interleaving_probe.py) ran E1/E2/E3, injected one raw noncoordinated mutation, then ran E4. [Results](artifacts/baseline-interleavings.json) show that a raw Canonical edit and branch switch changed E4 output; `assume-unchanged`, `skip-worktree`, and `.git/info/attributes` filter changes after E2/E3 left E1 and E4 output identical, even though a later E2 or E3 read saw the new metadata. This is command-output evidence, not yet a measured production calculator return value. The current source has no explicit re-observation of E2/E3 after E4. These interleavings are outside the coordinated writer contract; they characterize the limits of defense-in-depth rather than a product promise of arbitrary external-writer atomicity.

Production-shaped DEBUG hook results, candidate parity, and performance are pending.

## Conclusion

Pending evidence; the production four-execution calculator remains unchanged.

## Artifacts

- [Baseline interleaving probe](artifacts/baseline_interleaving_probe.py)
- [Baseline command-output results](artifacts/baseline-interleavings.json)
