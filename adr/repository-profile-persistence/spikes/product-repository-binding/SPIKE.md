# Product Repository Binding Spike

## Related Decision

[Repository Profile Persistence](../../ADR.md): whether a Product repository owned Profile can be a replayable authority with explicit Product and hamii observations.

## Hypothesis

A review receipt containing a hamii observation, Product repository identity, immutable Product commit, and tracked Profile blob can reject measured stale and wrong-repository inputs. Rejecting a dirty Product worktree is a safe initial rule, but any check of a mutable worktree before a later patch remains a race unless the patch uses the pinned immutable source.

## Questions

- Can the same reviewed receipt be replayed after clean checkout of its exact Product commit?
- Does a source-only commit, mapping-only commit, dirty staged/unstaged/untracked file, or wrong repository invalidate it?
- Does a symlinked Profile or a Product branch transition between checks expose a gap?
- How do unrelated commits affect a conservative exact-commit binding?
- Which part is proven by an immutable Git object and which needs Product patch publication coordination?

## Prototype Scope

Use disposable Git repositories and a test-only read-only receipt verifier. Capture the exact tracked Profile blob, Product root history identity and commit, and hamii CLI observation token. Compare before/after Product transitions and replay at the original commit. No Product source patch is generated.

## Out of Scope

Production Profile persistence, Product patch publication, actual symbol validation, version migration, clean-worktree optimization, and a durable trust identity for remotes/forks.

## Measurements

Record each scenario and verifier verdict in `artifacts/results.json`. This is a correctness matrix; latency is not measured.

## Success Criteria

The receipt verifier rejects every measured changed or wrong input and accepts exact clean replay. A remaining mutable-worktree race and unrelated-commit false positive must be explicit.

## Failure Criteria

Any measured stale or wrong Product state is accepted as the reviewed state, or the prototype is described as a production authority.

## Result

**Observed, 2026-10-02:** `python3 artifacts/reproduce.py` completed against the locally built hamii CLI, a disposable hamii v3 repository, and two disposable Product Git repositories. The [machine-readable matrix](artifacts/results.json) records one run. The receipt verifier is Python test code; hamii production does not yet issue or enforce it.

The receipt captured the exact Product root-history OID set, commit OID, tracked Profile path/blob OID, Profile bytes SHA-256, and hamii `inspect.statePrecondition`. With a clean checkout at that commit, verification returned `current`; checkout back to that exact commit after other Product transitions returned `current` again. A different Product history containing the same valid Profile bytes returned `wrongRepository`. Source-only and mapping-only commits returned `staleProductCommit`. Staged, unstaged, and untracked Product files returned `dirty`. A tracked symlink at the Profile path was rejected at capture. A hamii mutation invalidated the captured hamii observation. Changing only the branch name while retaining the exact commit did not invalidate the receipt.

A Product documentation-only commit also returned `staleProductCommit` even though source and Profile bytes did not change. That is a conservative false-positive of exact-commit binding, not a stale acceptance. The prototype uses Git object bytes for the Profile at the pinned commit; mutable worktree bytes must match at capture. Exact commit replay identifies an immutable Product input, but a check followed by a patch into the live Product worktree has an unclosed check-to-write race. Any Product patch must use the pinned immutable input in an isolated candidate and recheck publication preconditions. This Spike did not implement or verify that publication path.

**Inferred boundary:** an initial exact-commit binding can be correct with extra invalidations if users accept refreshing a plan after every Product commit. A more selective source identity would reduce false positives, but determining a safe relevant-source set requires Product repository analysis outside this Spike. Root-history OID equality is only a test identity: shallow histories, forks, remote trust, and repository relocation need explicit product rules. Existing Profile v1 parsing and malformed/version errors remain as measured in the preceding [placement Spike](../storage-location-and-binding/SPIKE.md).

**Unknown / not implemented:** production receipt issuance, Product repository identity trust policy, isolated patch candidate/publication, simultaneous hamii save and Product Git transition, Product symbol existence checks, and independent future Profile migration. A sequential replay and test-only verifier do not establish production atomicity.

## Conclusion

A Product-tracked Profile plus an immutable Product commit and exact hamii observation can reject the measured stale/wrong cases in a test-only verifier. The experiment does not prove a production authority or the Product patch publication race. The ADR remains `Spike Required` pending an accountable placement/binding decision.

## Artifacts

- [Disposable binding reproduction](artifacts/reproduce.py)
- [One machine-readable result](artifacts/results.json)
