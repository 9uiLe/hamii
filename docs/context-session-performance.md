# Context session Release comparison

Production source: `2d7d7815238511ba93018d0e30ebc39900b61de0`. Measurement date: 2026-09-30. [Raw paired samples](measurements/context-session-cli.json) retain every measured attempt, timing, response hash, bytes and structural operation counts from the final harness. An [initial run](measurements/context-session-cli-initial.json) is also retained: its source preflight used tracked diffs; the final harness additionally rejects untracked production files. The timer and production executable are unchanged. Both rounds contain ten pairs per shape/task; no measured attempt failed or was discarded. The table below reports the final round, without pooling the rounds.

## Conditions

Swift 6.4 Release, macOS 27.0 arm64, 10 logical CPUs; one local workflow at a time, warm filesystem cache, no concurrent local full gate. Each candidate received one unmeasured warm-up per shape/task. Ten paired iterations alternate which candidate runs first. The timer starts before process launch and ends when the last required response arrives; fixture preparation, Release build, final close and final process reaping are excluded. CURRENT uses independent one-shot CLI processes; SESSION uses one process with NDJSON follow-ups. Machine load averages and the executable SHA-256 are in the raw record. Run the reproducer without another full gate or heavy job; the script does not continuously monitor other processes.

All fixtures contain 10,002 Layers and the same selected UI/resources. L has one large Screen shard (12 Canonical paths), S has 100 Screen shards (111 paths), and C distributes Layers across Components (112 paths, 102 Components). Canonical bytes are 2,832,248 / 2,887,615 / 2,913,736 respectively. The [shape builder](../scripts/measure-shard-observation-shapes.py) is shared with the observation-reuse evidence.

T1 retrieves selected Text summary/detail. T2 retrieves parent summary/detail, matching Component resources and selected Component detail. T3 retrieves parent summary/detail, matching Token resources and selected Token detail. This measures context retrieval, not an entire AI authoring task.

## Time

Times are milliseconds. Each row has ten pairs. Min/max show the observed range; no p95, throughput or Product SLA is inferred.

| Shape | Task | CURRENT median (min–max) | SESSION median (min–max) | SESSION / CURRENT |
| --- | --- | ---: | ---: | ---: |
| L | T1 | 189.205 (186.533–191.415) | 96.475 (94.223–116.398) | 0.510 |
| L | T2 | 381.753 (378.061–383.468) | 101.352 (99.087–103.233) | 0.265 |
| L | T3 | 381.153 (377.868–385.584) | 100.885 (99.712–102.179) | 0.265 |
| S | T1 | 211.947 (208.639–213.647) | 110.492 (109.780–112.014) | 0.521 |
| S | T2 | 423.873 (420.318–428.062) | 124.244 (123.350–127.098) | 0.293 |
| S | T3 | 425.266 (422.510–426.972) | 124.308 (121.693–127.092) | 0.292 |
| C | T1 | 213.450 (211.419–217.459) | 111.866 (109.746–114.859) | 0.524 |
| C | T2 | 432.820 (429.253–433.803) | 127.553 (126.487–131.360) | 0.295 |
| C | T3 | 431.725 (427.843–435.420) | 125.575 (124.760–127.180) | 0.291 |

The precommitted criterion in [the ADR](../adr/context-observation-reuse/ADR.md) is SESSION median ≤70% of CURRENT for both T2 and T3 in every shape. All six final-round comparisons pass (ratios 0.265–0.295). The initial round also passes, with ratios 0.264–0.295. T1 is reported without a threshold. These results support this Release warm-local retrieval path; they do not establish cold-cache, hosted-runner, arbitrary external-writer or large-Project guarantees.

## Output, work and cost

| Task | Responses | CURRENT / SESSION processes | CURRENT / SESSION full observations | SESSION freshness verifications | SESSION stdin request bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| T1 | 2 | 2 / 1 | 2 / 1 | 1 | 127 |
| T2 | 4 | 4 / 1 | 4 / 1 | 3 | 397 |
| T3 | 4 | 4 / 1 | 4 / 1 | 3 | 387 |

Observation/verification counts are structural counts checked by Application regression tests, not runtime profiling counters. CURRENT independently validates every full observation; its zero lightweight verification count does not mean it skips freshness validation. Request bytes include follow-up newlines and exclude the 15-byte close request. One-shot stdin is empty; argv/tool-provider overhead is not counted here.

All 180 measured pairs across both rounds have identical raw `Output` response bytes and equivalent context observations. Context-only UTF-8 output totals are unchanged: T1 1,241–1,243 bytes, T2 2,776–2,777 bytes, T3 2,299–2,300 bytes. These bytes are a payload measure, not AI tokens. AI total tokens, model/cache billing, LLM task success, whole development-cycle latency, peak memory and local resource cost are unmeasured. Session memory lives until close/EOF/terminal failure; no daemon or persistent cache is introduced.

## Correctness and limits

[The real-process regression](../scripts/test-context-session.py) verifies response equivalence; strict usage errors and bounded oversized-line recovery; Scope-unavailable resources; EOF/close; a separate writer while the session is idle; equal-revision managed branch switch; pending gate; corrupt epoch; and restart. Failures return no context, terminal freshness/storage errors end the session, and mutations still use `ProjectService` preconditions. Application tests cover exact observation/verification counts, permanently invalidated sessions, journal recovery and additional coordination corruption cases.

Transport commit `2d7d781` passed [exact-SHA Verify](https://github.com/9uiLe/hamii/actions/runs/36651548078): 14 checks, 291 tests, 62 intentional opt-in skips, zero failures. Release build also succeeded. SIGKILL/process behavior does not establish power-loss durability. The context-observation-reuse ADR remains `Implementation Required` pending the measurement commit verification and closure review. Canonical sharding and CLI taxonomy decisions remain separate.

## Reproduce

```sh
python3 scripts/measure-context-session-cli.py --output /tmp/hamii-context-session-cli.json
python3 scripts/verify-change.py --base HEAD --include-worktree --expected-mode full
```

The measurement command builds the repository Release product, rejects uncommitted production-source changes, creates and validates disposable fixtures, records partial results on failure, and returns failure if any precommitted T2/T3 ratio exceeds 0.70. Read `completed`, `allThresholdsPassed`, `failure` (if present), and per-task `pairs` in its JSON. A partial file is not a successful result. Full gate details are in the bounded verdict’s `log` path; CI evidence is attached to its exact run.
