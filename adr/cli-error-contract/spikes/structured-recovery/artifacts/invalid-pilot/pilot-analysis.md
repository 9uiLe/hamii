# Invalid first S-arm pilot

This pilot is **excluded from the S/P comparison and every CLI error-contract decision**. It followed plan commit `f4c340380cb461a878be018a2c2f23047f12b136` (Verify `36732100349` success), but the operator preflight did not exercise recovery inside the actual Codex sandbox. The first eight S sessions finished; the ninth was explicitly cancelled and P was not started. All nine records remain under `trials/`; `pilot-matrix.json` preserves unrun cases.

## Observed outcomes, not accepted comparison results

| Case | Runtime | Frozen oracle | Observation |
| --- | --- | --- | --- |
| usage | complete | pass | Requested token created. |
| notFound | complete | pass | Existing component found and instantiated. |
| validation | complete | fail | Valid token created and validated; agent chose `fixInputAndRetry` instead of the narrower `fixSemanticInputAndRetry` label. |
| approval | complete | pass | Stopped for human approval. |
| conflict | complete | pass | Reobserved and retained intervening mutation. |
| transitionPending | complete | fail / oracle execution error | `hamii git recover` returned `git/7` in sandbox. Pending gate remained. |
| staleIndex | complete | fail | `hamii index rebuild` returned `staleIndex/8` in sandbox. No stale result was served. |
| migrationRequired | complete | pass | Planned migration and stopped for review. |
| unsupportedCapability | cancelled (`-15`) | unusable | Agent process was interrupted when the matrix was stopped; no completed-runtime claim. |

The nine starts consumed **1,009,959 reported agent input+output tokens** and **621.779 seconds of summed session wall time**, including the cancelled session. These values measure this invalid pilot only. They are not pooled with the new matrix or interpreted as a schema performance result. Operator planning, preflight, analysis, and CI tokens/cost remain unmeasured.

## Why the pilot is invalid

1. `operator-preflight.json` and `proxy-preflight.json` verified all nine real category/exit pairs and 18 message treatments outside the Codex sandbox. They did not prove that the supported recovery commands work inside it.
2. In `transitionPending`, the agent-visible CLI was allowed, but managed Git rejected the worktree root. In `staleIndex`, verified Git state could not be established, so the index rebuild correctly failed closed. This is an **environment equivalence failure** for the experiment, not evidence that either error category is insufficient.
3. The frozen shell audit searched for the word `git` in a command string. That would classify permitted `./hamii ... git recover` as raw Git. It should instead inspect the executable in argv. The first transition session's oracle raised before that audit result was exposed.
4. `validation` demonstrated an action taxonomy ambiguity: it successfully corrected a negative spacing value, but the two action labels `fixInputAndRetry` and `fixSemanticInputAndRetry` distinguish wording more than recovery strategy. The revised plan will use one recovery class and retain `usage` versus `validation` as separate production categories.
5. The ninth session was cancelled while running; its result file is not a completed trial despite a partially written decision artifact.

The initial hypothesis that **relative `--project` alone** caused the Git failures was retracted. Operator-only tests in a normal shell succeeded with both relative and absolute project paths. A read-only diagnostic in the actual Codex sandbox showed `/usr/bin/git` exit 0 while emitting `xcrun` cache errors and Xcode warnings on stderr. The then-current Git adapters combined stdout and stderr before parsing Git output. Commit `956508865b774eea191f827d87e92f87c8f28893` separated those channels and removed the temporary `check-attr` input file; its exact-SHA Verify run `36742941234` succeeded. With that binary, `git recover` passed the actual sandbox preflight.

The first post-fix `index rebuild` preflight then failed with SQLite `readonly database`. This was a separate launcher permission mismatch: Python `Path.resolve()` turned the fixture's `/var/...` worktree path into `/private/var/...`, while `LocalIndexLocation` used `/var/...` in its worktree namespace hash. The launcher granted the sandbox the wrong derived Index directory. After granting the exact Swift-visible namespace, fresh operator-only preflights passed both `git recover` and `index rebuild`; see `../preflight/actual-sandbox-preflight.json`. Neither preflight is an agent trial or a structured error comparison result.

No pilot success or failure is reused selectively. The new matrix, if its hard gates pass, begins with 18 new workspaces, sessions, and index namespaces and reports its own measurements separately.
