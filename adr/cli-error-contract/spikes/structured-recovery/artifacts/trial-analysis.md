# Fresh structured-error recovery matrix

This is Decision Evidence for `adr/cli-error-contract/ADR.md`, not a production error-schema decision. The first S-arm pilot under `f4c3403` remains invalid and excluded; its nine starts are in `invalid-pilot/`. This matrix uses 18 new Codex sessions, workspaces, project fixtures, and private Index namespaces.

## Frozen conditions and gates

- Product correction: `956508865b774eea191f827d87e92f87c8f28893`, exact-SHA [Verify run 36742941234](https://github.com/9uiLe/hamii/actions/runs/36742941234) succeeded. The correction separated Git stdout/stderr and removed the temporary `check-attr` input file; it did not change the CLI error schema.
- Plan commit: `c9a50cdbb0e7f0602a41b6e1a6ce9a6e6e6d6941`, exact-SHA [Verify run 36747742840](https://github.com/9uiLe/hamii/actions/runs/36747742840) succeeded. Local full gate: 14/14 checks, 296 tests, 61 skips, zero failures, 364.406 s.
- Release binary SHA-256: `483e58de638d6fbf8023a51368d9ad9b4a6f34336cbdcf643167ae33210509c5`; prompt SHA-256: `0ceec83ee11a6f00d03444a5e17c66290c73458684ebfc7f7b6c6c9b0eaf225b`. All 18 records match both hashes.
- Runtime: `codex-cli 0.159.1`, model `gpt-6.1-sol`, high reasoning effort, never approval, workspace-write sandbox, network disabled, one session per case, 300 s and 40 tool-call bounds. S ran nine cases in planned order; P ran the reverse order. S hid only failed JSON `message`; P showed the unmodified production JSON. Both used the same Release binary, instruction template, fixture logic, skills, and independent oracle.
- Operator-only controls: nine real category/exit pairs, 18 exact proxy treatments, nine positive and negative oracle controls, seven shell executable controls, and actual Codex sandbox `git recover` and `index rebuild` preflights passed. The first post-fix Index sandbox preflight failed because the launcher granted a `/private/var` namespace while Swift used `/var`; that setup failure is recorded separately and excluded.

## Observed results

Every trial had runtime exit 0, a complete result artifact, and a passing independent oracle. No timeout, tool-budget hit, parse error, forbidden action, direct Canonical/SQLite edit, unsafe approval escalation, or policy weakening was observed. A safe stop with human review counted as correct for approval, migration, and unsupported capability.

| Case | S result | P result | S / P wall seconds | S / P agent tokens |
| --- | --- | --- | ---: | ---: |
| usage | pass | pass | 63.83 / 60.64 | 136,248 / 126,624 |
| notFound | pass | pass | 58.19 / 62.49 | 137,225 / 125,541 |
| validation | pass | pass | 50.69 / 65.49 | 125,049 / 128,283 |
| approval | pass | pass | 42.02 / 42.59 | 76,456 / 76,538 |
| conflict | pass | pass | 43.09 / 39.87 | 109,331 / 116,451 |
| transitionPending | pass | pass | 70.72 / 78.29 | 156,820 / 127,405 |
| staleIndex | pass | pass | 102.53 / 102.02 | 205,490 / 172,921 |
| migrationRequired | pass | pass | 51.30 / 38.84 | 107,062 / 75,489 |
| unsupportedCapability | pass | pass | 78.32 / 76.69 | 144,698 / 158,935 |

Arm S total agent runtime: 560.689 s, 1,198,379 input+output tokens, 62 CLI attempts, 40 discovery calls, 39,698 CLI output bytes. Arm P: 566.904 s, 1,108,187 input+output tokens, 60 CLI attempts, 37 discovery calls, 38,792 CLI output bytes. Both arms made one additional failed CLI call in `transitionPending`, then recovered through the supported command. Agent input tokens were 1,192,679 (S) and 1,102,177 (P); cached input is nested within those amounts, 1,063,680 and 957,696 respectively. Agent output tokens were 5,700 and 6,010; reasoning output is nested within those amounts, 693 and 936 respectively. Cached and reasoning counts were **not** added again.

These measurements start at agent launch, after operator fixture creation and the initial CLI error, and stop after the independent oracle. They do not include operator planning, fixture setup, product correction, local gates, CI waits, analysis, integration, or this report. Whole-cycle AI tokens and monetary cost are **unmeasured**. The invalid pilot's 1,009,959 reported agent tokens and 621.779 s are excluded from every number above.

## Interpretation and limits

For these nine production errors, the structured-only S arm selected the correct recovery or safe stop in all nine fresh sessions; retaining `message` did not change correctness in the paired P sessions. This supports a narrow sufficiency finding for the tested fields and tasks. It does **not** settle diagnostic envelope versioning, every exit-code allocation, or long-term compatibility. The ADR remains `Spike Required` pending Decision Review.

There is one trial per case and arm, case difficulty varies, and the arms ran in opposite orders. The wall and token differences do not establish that either arm is faster or uses fewer tokens; no p95, confidence interval, throughput, whole-cycle token reduction, or cost saving is claimed. A correct outcome may still contain extra CLI discovery or a recoverable additional error. The independent oracle and per-session records in `trials/` are the source for each result; `trial-matrix.json` and `progress.json` are bounded summaries.
