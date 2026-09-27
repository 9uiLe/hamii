# Git lock ownership during publication recovery

## Related Decision

[Validated merge publication](../../ADR.md): pending recovery must preserve the Canonical publication gate until it can safely resume or abort.

## Hypothesis

A pending hamii publication record and a Git lock file's presence do not prove that the lock belongs to the interrupted hamii Git subprocess. A live, non-coordinated Git process can create the same lock after hamii stops.

## Questions

- Can a live Git process hold `.git/refs/heads/<branch>.lock` while hamii publication is pending?
- Can a live Git process hold `.git/index.lock` in the same state?
- Can pending-record phase or lock-file existence distinguish those locks from files left by a stopped hamii subprocess?

## Prototype Scope

Run [probe.py](artifacts/probe.py) in a disposable Git repository. Pause an external `git update-ref` in a `reference-transaction` hook and an external `git add` in a clean filter. Inspect the corresponding lock paths and process liveness while each Git command is paused. Compare their observable lock paths with the production recovery deletion sites.

## Out of Scope

General safety for arbitrary same-worktree external writers, power-loss durability, Git lock format compatibility, and a production ownership protocol.

## Measurements

Record whether each lock exists, whether its Git process is alive, and its byte length at the pause. This Spike does not benchmark latency.

## Success Criteria

Either identify an ownership proof that survives hamii process death, or demonstrate a live external Git process with the same lock path that production recovery currently deletes. A safe production fallback must keep the pending gate and refuse automatic cleanup when ownership is unknown.

## Failure Criteria

Treating a lock's presence, file size, or a pending hamii publication record alone as proof of ownership; deleting a live external Git process's lock.

## Result

**Confirmed in one disposable repository on macOS 27.0 / Git 2.52.0:** the paused external `git update-ref` was alive and held `.git/refs/heads/main.lock` (41 bytes). The paused external `git add` was alive and held `.git/index.lock` (0 bytes at this pause). Both processes were still running when observed. The two paths are exactly the paths removed by `ValidatedMergePublisher.removeInterruptedGitLock` during old-ref and candidate-ref recovery. The probe did not use hamii's worktree lock; raw Git can create either lock while a hamii pending record exists.

**Inferred for production:** a pending publication record plus lock-file existence is insufficient to assign ownership. This experiment does not establish a safe way to automatically remove locks left by a stopped hamii Git subprocess. Absence of a live file descriptor would not, by itself, prove ownership either.

## Conclusion

Automatic deletion based only on the pending record and lock path is unsafe. When Git lock ownership is unknown, recovery must preserve the pending gate and fail closed. This is a focused recovery implementation requirement under the existing publication decision; it does not reopen the Product Contract or settle a general external-writer protocol.

## Artifacts

- [Disposable Git lock probe](artifacts/probe.py).

