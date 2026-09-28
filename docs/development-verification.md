# Development verification

## Gates and commands

The usual local command checks committed changes since `HEAD` plus staged, unstaged, and untracked files:

```bash
python3 scripts/verify-change.py --base HEAD --include-worktree
```

For a committed change, compare the exact parent and head:

```bash
python3 scripts/verify-change.py --base HEAD^ --head HEAD
```

The only narrow gate is a diff confined to `README.md`, `AGENTS.md`, `docs/**/*.md`, and `adr/**/*.md`. It runs ADR structure and local link validation. Its result explicitly reports that Swift build and tests were not run. Any source, test, sample, workflow, script, configuration, generated artifact, unknown path, or ambiguous Git boundary selects the full gate. A source file renamed into a Markdown path also selects full. The full gate runs the same Swift build, app signing, tests, architecture checks, CLI smoke tests, and sample validation as `scripts/check.sh`. Cheap static checks run before Swift build so malformed ADRs, broken links, and architecture dependency violations fail earlier.

`verify-change.py` emits one JSON line with mode, status, exit code, changed file count, duration, test count or explicit non-execution, and a log path. It preserves the check's nonzero status. Full logs are under `.build/verify-logs/`; CI uploads them as a seven-day `verification-log` artifact. The JSON failure tail is bounded, while the full log retains context. An empty or unverifiable diff falls back to full. To inspect a failure, read the JSON `failureTail` and then the named log. Run `bash scripts/check.sh` explicitly whenever a full gate is required regardless of diff.

The local wrapper stops its process group after 120 seconds for a documentation gate or 3,600 seconds for a full gate, reporting timeout rather than success. `--timeout-seconds` can override this for a deliberately longer local investigation. CI has a 65-minute job limit. A timeout or cancellation leaves a partial log and requires diagnosis; it never authorizes reusing the incomplete result.

The CI `Verify` job selects the gate from the exact event base and checkout head. It installs Swift 6.4 only for the full gate. The GitHub Actions run for the pushed SHA is the delivery result; a green local result or a different SHA does not replace it. Do not edit the worktree while a local gate is running. A changed input invalidates that result and requires another run.

After pushing, use `python3 scripts/wait-ci.py --sha "$(git rev-parse HEAD)"` to wait for the exact `Verify` run. It returns one JSON verdict and a nonzero exit on failure or timeout; a timeout is **not** a successful run. For a failed run, inspect the reported URL or `gh run view RUN_ID --log-failed`, fix the cause, and verify the new pushed SHA.

## Evidence and limits

The prior README said, “Swift 6.4 build/test、module dependency、ADR/Spike 形式、CLI smoke test を実行します。CI も同じ入口を使います。” In the prior workflow, every push and pull request called the full `scripts/check.sh`. The first affected path was therefore the CI gate itself, not the Swift build cache.

Historical, successful Markdown-only GitHub Actions runs provide a baseline. These are different commits on macOS hosted runners, so they are observational rather than controlled paired trials. Job time includes setup, checkout, and Swift installation; verification step time is shown separately:

| Run / commit | Changed paths | Job time | Verification step | Outcome |
| --- | --- | ---: | ---: | --- |
| [36372909084](https://github.com/9uiLe/hamii/actions/runs/36372909084) / `36d54c76` | ADR and architecture Markdown | 1,627 s | 1,564 s | success |
| [36399916503](https://github.com/9uiLe/hamii/actions/runs/36399916503) / `3bd5aeb3` | README, ADR, architecture/performance Markdown | 1,634 s | 1,564 s | success |

In [run 36404353820](https://github.com/9uiLe/hamii/actions/runs/36404353820), a broader change used 1,502 s for 212 Swift tests (56 intentional skips, zero failures). Three suites accounted for about 1,321 s: Validated Merge Publication 742 s, Index Query Session 325 s, and Production Generation Shadow 254 s. These tests remain in the full gate. The Markdown-only path exercises the same two documentation validators that the full gate runs.

The local measurements below used arm64 macOS 27.0, Swift 6.4, Python 3.14, a warm `.build`, one verification process at a time, and the current worktree. For the documentation gate, five trials used the historical Markdown-only `3bd5aeb3^..3bd5aeb3` diff solely as classifier input while validating the current documentation. The worktree status was identical before and after. Wall time is command start to JSON verdict; gate time excludes classification and Python startup.

| Local path | Trials | Wall median (range; max) | Gate median (range; max) | Result |
| --- | ---: | ---: | ---: | --- |
| Documentation gate | 5 | 0.358 s (0.309–0.365; 0.365) | 0.150 s (0.142–0.160; 0.160) | ADR and links passed; Swift not run |
| Full gate | 1 | not recorded separately | 818.645 s | 217 Swift tests; 56 intentional skips; 0 failures; all 13 checks passed |

The local full run is a single observation, not a p95 estimate. An earlier trial was invalidated by editing `check.sh` while it was running: Swift completed 217 tests with zero failures, but the shell then exited 2 on a syntax error. That 785.782-second attempt is retained as a **failed/incomplete trial**, excluded from successful timing. The stable run followed after the script and summary parser were fixed. An injected broken link produced a nonzero validator result; an injected 1 ms timeout returned exit 124 and a partial log. A gate-mode mismatch also returned nonzero.

These local paths are not a paired CI comparison. CI job time starts when the runner job starts and ends when the job completes; gate time starts at the verification step. Neither series measures the first edit-to-verdict interval. The decision-ready CI comparison needs the pushed Markdown-only run below. A handful of runs cannot establish p95 or a product SLA.

The first full-gate CI run of the new workflow, [36415773072](https://github.com/9uiLe/hamii/actions/runs/36415773072) at `819e4502`, succeeded: 1,805 s job time, 1,723 s verification step, 217 Swift tests with 56 intentional skips and zero failures, all 13 checks passed. Its `verification-log` artifact was downloaded and the final test summary and smoke-check markers were confirmed. The older broad-change [run 36404353820](https://github.com/9uiLe/hamii/actions/runs/36404353820) took 1,749 s job / 1,671 s verification, with 212 tests. Different commits and runners prevent assigning the 56 s job difference to the new gate. The Swift test suite alone took 1,548 s in the new run, compared with 1,502 s in the older run.

As an output-volume proxy, the older CI log was 141,073 bytes / 895 lines; the new full CI log was 29,224 bytes / 267 lines, while its detailed test log remained available as a 9,751-byte compressed artifact. This measures GitHub log output, **not** AI total tokens, input cache use, model cost, or response time. The archive is retained for seven days, so long-term evidence is the run summary and this report.

AI total token usage for a task cannot currently be read from this repository or the active tool session, so it is **unmeasured**. Log bytes and repeated raw-output retrieval can be reported as proxies, never converted into token savings. The CI runtime and artifact transfer represent resource use; actual billing and model expense are separate and not inferred from elapsed time.

This repository is public and uses a standard `macos-latest` runner. [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) says standard hosted runners are free for public repositories. The change can still save runner capacity and developer waiting time. Artifact storage and any account-specific bill are not measured here; model expense is also unmeasured.
