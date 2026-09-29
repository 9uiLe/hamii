# AI context query measurements

## Measurement boundary

Production code source: commit `25225798c9c5e16a99edb15d88345aad1e208ebe`. The measurement uses the production `ProjectContextService` and `hamii query context` CLI; its fixture builder and timing harness are [measure-ai-context.py](../scripts/measure-ai-context.py) and `ContextPerformanceProbeTests`. Raw per-run results are in [ai-context-query.json](measurements/ai-context-query.json).

The measured machine was macOS 27.0 arm64 with Apple Swift 6.4. The script builds one disposable Git-backed project through `hamii init` and semantic CLI mutations, then clones it into 1,000- and 10,000-Layer cases. It adds deterministic Text siblings inside the selected Screen; the selected Text and parent Layer, Scopes, Component, and Token are identical in both cases. The fixture contains a Commerce-owned `PriceBadge`, a sibling Account-owned `PrivateBadge`, and a Checkout spacing Token. Both Current-format projects pass `hamii validate` before timing. The generated fixture is disposable and not a product collaboration workflow.

Run from repository root after `swift build --product hamii`:

```sh
python3 scripts/measure-ai-context.py --output docs/measurements/ai-context-query.json
```

The script measures ten calls per service operation inside one test process and five one-shot CLI runs per workflow. A CLI workflow launches a fresh process for each summary/detail response. Timings include process startup and Canonical observation for each CLI response. Service timings include `CanonicalRepository.observe()` in each operation but exclude the Swift test process startup. Fixture creation and source compilation are outside the timed intervals. The fixture creation warms filesystem cache; these results are neither a cold-cache measurement nor a Product SLA. The values below are medians and minimum–maximum ranges, not p95 estimates.

## Payload and query count

Each staged value is cumulative UTF-8 bytes of the production CLI JSON responses. FULL is one `hamii inspect --json` response. `S` includes a summary followed by a machine-readable `conflict` response after a disposable external edit; coordinated stale mutation safety is tested separately by production service and CLI tests.

| Scale | FULL bytes | T1 Text | T2 Component | T3 Token | N unavailable Scope | S stale |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1k | 168,343 / 1 | 1,284 / 2 | 2,863 / 4 | 2,386 / 4 | 1,712 / 3 | 840 / 2 |
| 10k | 1,680,339 / 1 | 1,284 / 2 | 2,864 / 4 | 2,387 / 4 | 1,713 / 3 | 840 / 2 |

Cells are bytes / response count. All five task paths meet the Spike's at-most-four responses, at-most-2× growth, and at-most-25%-of-FULL payload criteria in these fixtures. At 10k, T2's staged bytes are about 0.170% of FULL. This measures serialized response size, not model context tokens or cost. The measured task output excludes human/agent prompt text, retries, summaries, and other model calls.

## Latency

| Operation | 1k median (range), ms | 10k median (range), ms | Runs per scale |
| --- | ---: | ---: | ---: |
| Service summary | 12.334 (12.258–12.631) | 109.982 (109.597–112.664) | 10 |
| Service Layer detail | 12.383 (12.291–12.989) | 109.881 (109.536–112.111) | 10 |
| Service Component resources | 12.666 (12.397–13.299) | 110.055 (109.706–111.854) | 10 |
| Service Component detail | 12.431 (12.345–12.703) | 110.163 (109.797–112.017) | 10 |
| Service Token resources | 12.361 (12.302–12.463) | 110.133 (109.765–111.715) | 10 |
| Service Token detail | 12.953 (12.382–13.545) | 110.067 (109.689–111.064) | 10 |
| CLI FULL inspect | 29.435 (28.813–29.702) | 196.819 (196.029–200.381) | 5 |
| CLI T1 staged workflow | 43.194 (43.109–44.065) | 247.372 (246.073–248.545) | 5 |
| CLI T2 staged workflow | 86.726 (86.294–86.936) | 496.050 (493.518–496.468) | 5 |
| CLI T3 staged workflow | 86.172 (85.982–87.210) | 491.846 (489.714–494.259) | 5 |

The size-independent staged response bytes and size-dependent service times point to repeated Canonical observation as the dominant cost in these cases. Four separate 10k CLI calls take longer than one full `inspect` despite sending far fewer bytes. This is an inference from the measured operation times; no parser-level profile was captured. The current contract favors bounded relevant context and exact state checking. A long-lived or batched read session would require its own correctness validation before any speed claim.

## Correctness and limits

The production service tests use one observation per response, reject stale `ClientPrecondition` even when `DocumentRevision` is equal, keep Component/Token/Asset Scope filtering aligned with the existing evaluator, enforce the 32/100 item bounds, and execute T1/T2/T3 through `ProjectService.mutate`. CLI smoke validates structured context JSON and a stale follow-up after managed branch switch. The measurement harness verifies unavailable sibling Component exclusion and stale `conflict` output. The first measurement attempt tried a semantic mutation after a synthetic Screen shard was written with Python's JSON formatting; expected-bytes Canonical save correctly rejected that noncanonical source. The final stale payload probe uses an external edit only, while coordinated mutation behavior remains covered by the production tests.

Additional Screen-graph shapes, larger Scope / Component / Token sets, concurrent writers, visual tasks, and real agent workflows were not measured here. **AI total tokens: unmeasured. LLM task success: unmeasured.** No byte-to-token, model-cost, or end-to-end AI development-cycle reduction is inferred from these results.
