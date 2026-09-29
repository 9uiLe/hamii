# Isolated migration review/publication comparison

## Observed fixture and exact review object

The test copies Starter into a temporary Git worktree, saves one `paddingTokenID` and one content-addressed Repository asset with the current v1 writer, then commits a clean source. Candidate preparation reads the source OID, creates a detached worktree at that OID, runs the Foundation-only raw edge graph, checks each intermediate candidate through an outer test-only v1 semantic adapter, and completes a fresh LocalIndex rebuild before committing and retaining the candidate. The candidate commit has the source commit as its sole parent. The production Format still understands only v1.

The clean acceptance case in [review-publication-matrix.json](review-publication-matrix.json) recorded source OID `275924925fcd0bcc9fe95714dc17c9cbc9b7aaf1`, candidate OID `ca181083dfa8d60ba7b74011d448439e270a8a50`, source tree `c3c868dc87374c986d967fd0ccd13e4336c7736f`, and candidate tree `7a0d1b908e1bd3f60f44792529c269951ebbd865`. The exact `git diff --name-status` was `M hamii.json` and `M screens/screen_9369ecd6-58a4-47e1-a455-2c62eee99a4d.json`; `git diff --stat` reported two files, ten insertions, five deletions. No unexpected Canonical path changed. The same source tree produced the same candidate tree across all 21 recorded cases. Candidate commit OIDs varied with commit metadata and were never used as the rerun determinism criterion.

## Workflow options

| Option | Review identity | Dirty user data | Publication and recovery | Finding |
| --- | --- | --- | --- | --- |
| Detached worktree at exact source OID + retained candidate commit | Exact source/candidate OID pair and tree/diff | Tracked and untracked changes reject start | Expected-source-OID ref CAS; pending old/candidate/neither classification | Tested 21 cases; supports review without changing the source worktree before acceptance |
| Mutable migration branch tip | Branch name can move after review | Requires a separate dirty-tree gate | A branch name alone does not identify reviewed bytes | Do not use mutable tip as approval identity; no further prototype needed for this decision |
| Source worktree in-place transform | Source changes before review | Risk of mixing/overwriting user edits | Failure would need rollback of canonical user data | Violates the required pre-review source preservation boundary |

The source-moved case made an independent clean commit after review. A detached **negative-control** worktree could text-merge the candidate into that new source commit, but the migration publisher rejected it because the reviewed expected source OID no longer matched. A second interleaving changed the source ref after pending and before `git update-ref`; the expected-OID CAS itself rejected publication, leaving the pending gate closed. No cross-format merge is part of the proposed publication path.

## Fail-closed cases

- Dirty tracked and untracked Canonical-looking files were rejected before candidate creation; the tests never stashed or auto-committed them. The matrix's `sourceBytesPreserved=false` on these two rows means the **user's own** source edit differed from the committed baseline, not that migration changed it.
- Removing a token shard from the detached candidate produced `token.missing`; removing the required repository blob produced `asset.integrity`. Neither candidate reached retained review-ready state. This proves generic missing-object rejection for this fixture, not Git LFS transport.
- A candidate worktree edit after review created a different OID. The retention ref still pointed to the reviewed OID and the altered review request was rejected. Review rejection explicitly removed its candidate worktree/ref and left the source unchanged.
- A failed Index rebuild after successful ref CAS left the ref at the candidate and the pending gate in place. Recovery revalidated the candidate and rebuilt a fresh test index before clearing the gate. Unknown source ref OID left the gate in place. Recovery after old ref aborted publication; recovery after candidate ref rolled forward.
- Five helper-process SIGKILL stops covered transform, pending, ref published, current validation, and Index published. A second OS-process reader reached the shared worktree lock only after the stopped writer was killed. During transform it observed Ready on the untouched source; at the four publication stops it observed pending. These are process-crash ordering observations, not APFS/fsync or power-loss evidence.

## Limits and implementation handoff

`WorktreeCoordinator.withExclusive` and client-epoch invalidation are existing production primitives. The migration-specific pending record and access gate in this Spike are test-only. Normal production `CanonicalRepository`, CLI, Preview, and Query paths do not yet consult this marker. The `indexPublished` phase denotes a completed fresh LocalIndex rebuild through a **test-only v1 adapter**; it is not a published production Index generation for v2/v3 bytes. The production orchestrator must connect the same coordination boundary, migration pending gate, target Current Format validator, Index generation publication, and idempotent recovery before any migration can be used.

The test did not transfer Git LFS objects or test power loss. A SIGKILL during detached-worktree transformation left temporary storage to clean; the source branch/ref/Canonical files remained unchanged. The test cleanup removed the orphan worktree after restart. Cleanup failure would consume temporary space but would not authorize source publication. The current v1 source fixture can be read by production Format; an actual old-format source may not, so production migration preparation must use raw historical parsing and exact Git source identity rather than relying on a Current Core load.
