# Git CLI capability closure

## Related Decision

[Git CanonicalRevision observation protocol](../../ADR.md): can the E1–E4 evidence be collected with fewer than four real Git executions while preserving the tested baseline behavior?

## Hypothesis

The documented one-shot Git CLI surface available to production's `/usr/bin/git` does not expose a complete pair of E1, E2, E3, or E4 evidence classes in one invocation. A finite pairwise capability matrix can close this option without another arbitrary three-call prototype.

## Questions

- Which evidence classes can a single documented Git invocation expose completely?
- Where do commands expose only a subset, such as `ls-files` working-tree categories without `branch.oid`, or `--eol` without `filter`?
- Is there a baseline-equivalent three-call composition on the installed Git?
- Is an in-process Git metadata reader justified by the measured cost and its semantic maintenance burden?

## Prototype Scope

Map E1 initial branch/HEAD and Canonical working-tree status, E2 tracked Canonical paths and hidden index flags, E3 tracked paths' `filter` attribute, and E4 a final branch/working-tree status observation. Classify all six pairs as supported, partial/insufficient, or unsupported using official command documentation and focused `/usr/bin/git` 2.54 probes in a disposable repository. Count real Git executions. This is a CLI capability probe, not another candidate calculator.

## Out of Scope

Production calculator changes, in-process Git metadata implementation, persistent Git protocols, shell/alias wrappers that spawn multiple Git children, Index recovery, arbitrary external-writer atomicity, and a new CanonicalRevision encoding.

## Measurements

Record the installed Git binary/version, each probed command and exit status, relevant output fields for clean, hidden-flag, and active-filter states, and the pairwise capability matrix. Preserve the already measured four-call timing and rejected `ls-files -v --eol` candidate as separate prior evidence; this Spike does not make a new latency claim.

## Success Criteria

All six pairs have evidence-backed classifications, with explicit missing fields or temporal guarantees. A three-call composition is considered possible only if it covers E1–E4 and preserves E1/E4 as distinct observations, hidden-flag and active-filter rejection at their relevant checks, and the baseline branch/working-tree fence.

## Failure Criteria

Treating two child Git invocations as one, equating end-of-line attributes with `filter`, substituting an index blob OID for `branch.oid`, relabeling a single observation as two temporal fences, claiming a mathematical impossibility from a bounded CLI survey, or adopting a production optimization without correctness evidence invalidates the conclusion.

## Result

The [focused probe](artifacts/probe_git_cli.py) ran against the same `/usr/bin/git` binary used by the production calculator: `git version 2.54.0 (Apple Git-157)`. It created a disposable repository and recorded clean, pre-existing `assume-unchanged`, pre-existing `filter`, and mixed changed/renamed/untracked states. [Normalized outputs](artifacts/git-cli-capability-results.json) include every command and exit status. The separate `git` on this machine's shell `PATH` is Homebrew Git 2.52.0; the results below refer specifically to `/usr/bin/git`.

Evidence definitions remain E1 = initial branch/HEAD OID and Git-reported Canonical working-tree status; E2 = all tracked Canonical paths and hidden index flags; E3 = each tracked path's `filter` attribute; E4 = a later observation of the E1 branch/working-tree state. E1/E4 are distinct times, not merely two fields in one output.

| Pair | Complete in one documented Git execution? | Evidence and missing requirement |
| --- | --- | --- |
| E1 + E2 | **Partial / insufficient** | `ls-files -v -c -m -d -o --exclude-standard` reports some working-tree categories and hidden flags. The mixed fixture gave `H` and `C` rows for one modified path, `?` for an untracked path, and no rename record or `branch.oid`. Conversely, porcelain-v2 `status` reports `branch.oid` and a `2 R.` rename entry, but omits unchanged tracked paths and hidden flag tags. Neither output alone provides the pair. |
| E1 + E3 | **Unsupported** | Porcelain-v2 `status` has branch and changed-path records, not arbitrary gitattributes. `check-attr filter` takes paths and returns attribute values, not branch/working-tree status. The active-filter fixture left clean `status` unchanged while `check-attr` reported `hamii-probe`. |
| E2 + E3 | **Unsupported** | `ls-files -v --eol` reports flags plus end-of-line attributes, not `filter`; its active-filter output was unchanged. Documented `--format` fields do not include arbitrary attributes, and `ls-files --format=%(attr:filter)` exited 128. `check-attr` does not enumerate tracked paths or hidden index flags. This is also the mandatory parity failure of the [prior three-call candidate](../git-evidence-consolidation/SPIKE.md). |
| E2 + E4 | **Partial / insufficient** | `ls-files -v` can expose flags and some changed-path tags, but provides neither `branch.oid` nor porcelain-v2 rename semantics for the final fence. A final `status` provides that fence but not E2's complete tracked-path/flag evidence. |
| E3 + E4 | **Unsupported** | `check-attr` returns attributes for supplied paths but neither final HEAD OID nor working-tree status. Final `status` does not report the `filter` attribute. |
| E1 + E4 | **Unsupported as a single one-shot execution** | Even if one `status` output has all E1 fields, it is one observation. E4 must occur after E2/E3 and working-byte acquisition to reject the tested branch/raw-edit interleavings. A shell or alias spawning two `git status` children is two real Git executions. |

The official [status porcelain-v2 format](https://git-scm.com/docs/git-status) specifies `branch.oid`, changed/rename records, and untracked/ignored records, but no index flag or arbitrary gitattribute field. [ls-files options and fields](https://git-scm.com/docs/git-ls-files) specify tracked paths, `-v` flags, selected working-tree categories, `--eol`, and a finite `--format` field list; the listed OID is an index entry's object name, not the HEAD commit OID. [check-attr](https://git-scm.com/docs/git-check-attr) accepts pathnames and reports attribute values; it neither enumerates all tracked files nor reports branch status. The installed-Git outputs agree with those documented surfaces for the probed cases.

No surveyed documented one-shot command provides a complete pair. A baseline-equivalent three-call protocol would have to combine at least one pair while retaining distinct E1/E4 observation times. The bounded documented-CLI survey found no such composition. This does **not** establish mathematical minimality across undocumented commands, future Git versions, persistent processes, or in-process Git readers.

Option 3, an in-process reader, would need to preserve index flag semantics, gitattributes precedence and filter resolution, HEAD/index/worktree interactions, rename/ignored handling, and installed Git compatibility. That is a separate parser and maintenance burden. The measured clean-5000 Component four-call oracle p50/p95 of 383.23/383.32 ms is [local mechanism evidence](../../../../docs/git-canonical-revision-performance.md), not a Product SLA; no current evidence shows that a new in-process Git implementation would provide enough product value to justify its correctness risk. No Option 3 prototype was built.

Both prerequisite Verify runs succeeded: `18bc791` (run `36370347685`) and `38b1a11` (run `36370582138`). Local `scripts/check.sh` also passed with 188 tests, 50 optional skips, zero failures, and architecture/ADR/docs/CLI/merge/sample checks green. This Spike did not change the production four-call calculator or stale Index rejection.

## Conclusion

Within the surveyed documented one-shot Git CLI on production's Apple Git 2.54.0, Option 2 has no confirmed baseline-equivalent three-call composition. The prior concrete three-call candidate loses clean-filter rejection. Option 3 has substantial unvalidated semantic cost and is not required to make a bounded retain-or-replace decision. This evidence supports a decision to retain the four-call production protocol for now, without claiming theoretical minimality or arbitrary external-writer atomicity. The parent ADR remains `Spike Required` until that decision is recorded separately.

## Artifacts

- [Focused installed-Git probe](artifacts/probe_git_cli.py)
- [Normalized command/output evidence](artifacts/git-cli-capability-results.json)
