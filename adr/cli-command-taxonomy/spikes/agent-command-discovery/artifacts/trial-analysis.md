# Fresh-agent discovery evidence

## Conditions and boundaries

Eight serial, fresh `codex exec` sessions completed in the precommitted order: CURRENT-1, RESOURCE-1, VERB-1, TASK-1, TASK-2, VERB-2, RESOURCE-2, CURRENT-2. Each completed the same five tasks using the actual Release hamii through prefix translation. The initial Canonical bytes are identical in all trials: 12 paths, 4,976 bytes, digest `bf4e1a48867f30086063ae9839853e11edb3b7e0d146e924d53455991f39adb8`. Stable fixture IDs and names are fixed; generated mutation IDs and client observation tokens differ normally between worktrees.

The corrected plan `e871d49b12e80ba488527f045af05455c998ac03` passed [its exact-SHA Verify](https://github.com/9uiLe/hamii/actions/runs/36706859269) before trials. Production Sources, Package.swift and Package.resolved are unchanged from `1bf458a`. All eight binary and prompt digests match [runtime provenance](runtime-provenance.json).

Configured model: `gpt-6.1-sol`, reasoning `high`; Codex CLI 0.159.1, macOS 27.0 arm64, Swift 6.4. Server model revision is unavailable. Each new session has the same prompt, tool settings, workspace-write sandbox and a separate disposable project and local Index namespace. No resume/fork or carried conversation is used. Shell network and web search are disabled; project instruction bytes are zero. Task exposure, sandbox and command audit enforce the experiment boundary; they do not prove arbitrary host files are invisible.

The Release build already exists. Initial projects and Index namespaces are separate; OS filesystem cache, provider cache and host load are not experimentally controlled. Reported cache usage is retained rather than normalized away. Nine semantic skill group boundaries are identical across candidates; this is a prefix/group-name comparison, not a comparison of arbitrary skill regrouping. Catalog fairness is 6,065 / 6,099 / 6,172 / 6,224 bytes, max/min 1.0262; semantic fact unions match. No grammar, task, prompt or order changed after trials began.

## Correctness and discovery

| Candidate | Oracle tasks | Undiscovered attempts | Usage / other errors | Discovery calls per run | CLI attempts per run | Loaded skill bytes per run |
|---|---:|---:|---:|---:|---:|---:|
| CURRENT | 10/10 | 0 | 0 / 0 | 9, 9 | 27, 27 | 5,656, 5,656 |
| RESOURCE | 10/10 | 0 | 0 / 0 | 9, 9 | 27, 27 | 5,682, 5,682 |
| VERB | 10/10 | 0 | 0 / 0 | 9, 9 | 27, 28 | 5,757, 5,757 |
| TASK | 10/10 | 0 | 0 / 0 | 9, 9 | 27, 27 | 5,806, 5,806 |

All 40 tasks and final project validation pass the independent oracle. All eight completed machine command logs were reviewed. Every actual invocation is a tagged `./hamii` command; no source/docs/proxy/Canonical reads, direct edits, raw Git, web, context session, hidden ID/state helper or validation bypass was observed. No invalid, failed, timed-out, interrupted or not-run agent trial exists. All attempts have completion records. This claim is bounded by captured tool/command events; it is not a security isolation proof.

VERB-2 repeats `context.summary` once; both calls and outputs remain counted. TASK-2 loads context skill during T2 and uses it during T3; discovery attribution follows actual task labels, with no retrospective movement. All eight load the same eight semantic skills (bootstrap plus seven relevant skills) and one `skills list`. VERB's separate token group is named `create-and-alias`, found in the live catalog; it does not cause an undiscovered attempt. No candidate reduces observed discovery calls or guessing relative to CURRENT.

T1 is checked against real screen/token/layer values and entity counts; T2 verifies the correct component and no forbidden selection; T3 verifies requested IDs and a common exact observation; T4 captures actual validation and supported preview **plan** IDs/diagnostics; T5 captures the semantic contract and supported generated source. No Native Preview Host or transport result is claimed.

## Time: observed agent subset

Wall boundary: process launch through independent oracle completion. Fixture compile/setup, planning, harness failures, full gates, CI waits and decision review are outside this interval. Task command windows in JSON are first attempted command through last response for that tagged task; they are not claimed as agent task completion times.

| Candidate | Run 1 / run 2 seconds | Median seconds | Min–max seconds | Range seconds |
|---|---:|---:|---:|---:|
| CURRENT | 170.888 / 171.919 | 171.403 | 170.888–171.919 | 1.031 |
| RESOURCE | 162.992 / 161.098 | 162.045 | 161.098–162.992 | 1.894 |
| VERB | 165.124 / 173.649 | 169.386 | 165.124–173.649 | 8.525 |
| TASK | 151.373 / 158.048 | 154.710 | 151.373–158.048 | 6.675 |

These are descriptive n=2 observations with provider/runtime variance, not p95, throughput, an SLA, or statistically established taxonomy speedups. They do not measure change-to-final-acceptance cycle time. Candidate adoption is not decided by wall time alone.

## Tokens and cost

The installed runtime emitted authoritative aggregate `turn.completed.usage` for each session. The full raw usage objects are retained in each trial, including cached input, cache-write input and reasoning output. Total below is **input + output only**; cached input and reasoning output are not added again. Cache usage and total tokens are separate quantities.

| Candidate | Input tokens run 1 / 2 | Output tokens run 1 / 2 | Total tokens run 1 / 2 | Median total | Min–max total | Cached input run 1 / 2 |
|---|---:|---:|---:|---:|---:|---:|
| CURRENT | 445,928 / 431,479 | 2,202 / 2,293 | 448,130 / 433,772 | 440,951 | 433,772–448,130 | 413,952 / 400,512 |
| RESOURCE | 430,544 / 430,918 | 2,210 / 2,219 | 432,754 / 433,137 | 432,945.5 | 432,754–433,137 | 413,056 / 391,936 |
| VERB | 425,400 / 418,888 | 2,249 / 2,547 | 427,649 / 421,435 | 424,542 | 421,435–427,649 | 397,440 / 395,136 |
| TASK | 371,776 / 411,413 | 1,983 / 2,183 | 373,759 / 413,596 | 393,677.5 | 373,759–413,596 | 336,384 / 377,216 |

Total across these eight agent sessions: **3,384,232 reported tokens**. Token ranges are 14,358 / 383 / 6,214 / 39,837. This includes the measured sessions' discovery, implementation, verification and repeat calls. It does not include all operator/planning/integration/review/bridge/CI-check model calls. **Whole development-cycle AI tokens: unmeasured. Cost: unmeasured.** Subscription/billing cost and cache benefit cannot be inferred from this total. No bytes/characters-to-token conversion is made. These two observations per candidate do not establish a general token reduction or justify production migration alone.

## Failure retention and reliability checks

- Before any agent trial, the initial fixture referenced a spacing token unsupported by the static generator. The refusal, explicit fixture correction and corrected-plan identity are retained in [pre-trial preparation](pre-trial-preparation.json). Task semantics and candidate grammar were not changed during trials.
- Two operator-only preflight attempts failed the initial oracle's assumption that computed `TargetPlan.canPreview` was serialized. [Failure record](preflight-initial-failure.json) retains the failed check. The corrected predicate uses actual top-level success, exact Surface/Screen/Target IDs and zero diagnostics; it does not waive supported-plan validation.
- [Four successful preflights](preflight-results.json) run all tasks through production semantics before model calls. Negative controls reject missing context detail, mixed observations and an empty result set. They are harness checks, not agent successes or token measurements.
- The proxy does prefix translation and native execution only. Structured non-discovery output is passed through. No retries or state insertion occur. Agent runtime failure would stop the frozen suite and retain partial results rather than silently rerun it.
- Process timeout and tool budget are bounded and recorded, but this experiment does not claim exhaustive forced-timeout/descendant-process stress coverage. No such timeout occurred here.

## Interpretation and unresolved judgment

The tested CURRENT commands are discoverable without guesses and match all candidates on task success and discovery calls. Alternatives have no demonstrated improvement on those hard axes in this suite. TASK has lower observed session time and total tokens, with a substantial two-run token range and no reduction in discovery calls/loaded bytes. That is evidence for review, not a statistically established advantage or a whole-cycle claim. Migration and long-term naming consistency costs are qualitative and not benchmarked here. Future capabilities and different skill partitions are not covered by these tasks.

**No taxonomy decision or production rename is made.** Evidence is delivered for the subsequent Decision Review; retaining CURRENT remains a valid candidate. The ADR remains `Spike Required` until that review.

## Reproduction and detailed evidence

- [Matrix](trial-matrix.json) contains per-task/trial metrics and n=2 median/min/max/range; [trial records](trials/CURRENT-1.json) include actual structured responses and oracle evidence. Corresponding `*-machine.ndjson` files contain command/status/usage events only. Agent prose/private reasoning/full conversations are omitted deliberately.
- [Executed harness provenance](runtime-provenance.json) records exact script digests, initial bytes identity, model/configuration, binary/prompt identity, plan CI and failure retention. Executed scripts are retained exactly, including machine-local paths.
- After the repository full gate has built Release artifacts, run `python3 adr/cli-command-taxonomy/spikes/agent-command-discovery/artifacts/prepare-replay.py`. It relocates paths into a disposable harness, compiles the typed fixture, starts **zero** agent calls and prints the preflight command. Run that command for harness validation. [Replay verification](replay-verification.json) confirms this path compiles and all four candidates plus negative oracle controls pass without new model calls.
- For separately authorized new trials, pass `--ci-verdict <exact-current-HEAD-Verify-verdict.json>` to the preparer; it prints a new-trial command. That runner still requires exact HEAD CI success and unchanged production Sources relative to the recorded baseline. New trials consume model usage and must be separate evidence, not replacements for these eight.
- Original execution: `python3 /tmp/hamii-taxonomy-preparation/run-agent-trials.py --output /tmp/hamii-taxonomy-agent-evidence`. Replay changes only machine-local source/control paths, never grammar/task/prompt. Do not compare another runtime/model/cache condition as if it were this frozen suite.
