# Read-only partial-load Evidence

## Conditions and boundaries

Plan: `24d23cf` corrected before execution by `7d78095` to respect App/Checkout Token ownership. Source: `7d78095860e50fb261b79cb5451e423bbcc3614d`. Warm-local Release test-only Swift executable, Swift 6 language, Apple Silicon macOS, compiler/SDK/binary/object/script fingerprints and exact commands in [raw matrix](partial-load-matrix.json). Same common Foundation JSON serializer and aggregate boundaries as the scaling phase. Fixed sequential 1k/10k/50k × CURRENT-N/MONOLITHIC-N/SUBTREE-N, tasks full/A/B/C. One recorded excluded warm-up, ten measured samples each, no competing full gate. Task C requests the final leaf in the second subtree without a locator.

Each dependency-rich fixture has exactly the specified Layer count, two Screens, four child Stack subtrees and two single-Layer Component roots. The selected Stack uses an alias → primitive spacing Token, padding, a nested Component dependency, system Asset and Button → Interaction → Motion. Resource owners, Scope ancestors and explicit availability deny Scope are included. An unreferenced Asset and Screen B provide omitted-data controls. Candidate paths are fixed at 18/1/22; this is not many-shard scaling.

The full reconstructed Current parser and DocumentValidator establish the oracle outside partial timing. A partial read uses only request IDs, stable paths and already-loaded explicit references; no full Document decode, hidden locator, Index or directory enumeration. Its recursive on-demand closure is checked against a separate queue-based closure over the fully validated typed oracle. Semantic output bytes (including order and full dependency values), hashes, dependency IDs and read-path order match deterministically across ten runs.

Source binding is sorted exact path/byte SHA-256, length framed, called `measurementSourceFingerprint`. All 36 timing series pre/post fingerprints match. This binds an immutable disposable measurement fixture; it is not a concurrency/currentness guarantee.

## Completeness and correctness

270 measured partial runs, 90 measured full-open controls, 36 excluded recorded warm-ups; nine complete scale/layout cases. Every partial output matches the fully validated oracle and declares `globalValidityProven = false`, `authoringReady = false`. No runtime timeout, OOM, incomplete case or source drift in the accepted run.

At 10k each layout rejects nine missing/path/cyclic required-input controls plus malformed required JSON, returning no semantic payload. SUBTREE also rejects selected-path dangling, duplicate, unknown and identity-mismatched refs. Full reconstruction rejects all five subtree anomalies, including an unrelated unreachable shard; partial A intentionally does not prove global reachability. Unrelated Screen B missing-Token corruption leaves A's semantic output identical for every layout, while actual Current load/validation rejects `token.missing` (CLI storage error, exit 7). Total 38 retained corruption/control results. SUBTREE A opens only its selected subtree, no sibling subtree, Screen B or unreferenced Asset.

The tested closure includes Layer children and slot content; spacing/effect Token refs and aliases; Assets; nested Component definitions and API/variants/slots plus availability Scope refs; Interaction Motion refs; Scope parents. The fixture exercises nested Components, aliases, padding, availability deny and Motion. It does not exercise every API/variant/slot/custom-navigation combination; production support is not inferred from unexercised branches.

## Paired measurements

All rows n=10. Descriptive median/min/max only; fractions are measured bytes/counts against that layout's own inventory. No p95, SLA, throughput or universal speed claim.

| Layers | Layout | Task | Median ms | Min–max ms | Files read / all | Bytes read | Byte fraction | Time / full median |
|---:|---|---|---:|---:|---:|---:|---:|---:|
| 1,000 | CURRENT-N | full | 17.832 | 17.057–19.100 | 18 / 18 | 410,839 | 1.000 | 1.000 |
| 1,000 | CURRENT-N | A | 11.307 | 11.111–11.730 | 13 / 18 | 208,478 | 0.507 | 0.634 |
| 1,000 | CURRENT-N | B | 14.282 | 14.080–14.649 | 13 / 18 | 208,478 | 0.507 | 0.801 |
| 1,000 | CURRENT-N | C | 6.991 | 6.872–7.274 | 5 / 18 | 204,866 | 0.499 | 0.392 |
| 1,000 | MONOLITHIC-N | full | 15.244 | 15.061–15.583 | 1 / 1 | 444,559 | 1.000 | 1.000 |
| 1,000 | MONOLITHIC-N | A | 10.938 | 10.825–11.263 | 1 / 1 | 444,559 | 1.000 | 0.718 |
| 1,000 | MONOLITHIC-N | B | 14.141 | 14.005–14.834 | 1 / 1 | 444,559 | 1.000 | 0.928 |
| 1,000 | MONOLITHIC-N | C | 7.687 | 7.576–7.971 | 1 / 1 | 444,559 | 1.000 | 0.504 |
| 1,000 | SUBTREE-N | full | 18.145 | 17.937–18.451 | 22 / 22 | 315,201 | 1.000 | 1.000 |
| 1,000 | SUBTREE-N | A | 12.775 | 12.550–13.260 | 14 / 22 | 84,206 | 0.267 | 0.704 |
| 1,000 | SUBTREE-N | B | 23.690 | 23.483–24.417 | 15 / 22 | 160,575 | 0.509 | 1.306 |
| 1,000 | SUBTREE-N | C | 16.618 | 16.389–17.487 | 7 / 22 | 156,963 | 0.498 | 0.916 |
| 10,000 | CURRENT-N | full | 137.592 | 137.097–138.566 | 18 / 18 | 4,037,839 | 1.000 | 1.000 |
| 10,000 | CURRENT-N | A | 92.273 | 91.938–93.029 | 13 / 18 | 2,021,978 | 0.501 | 0.671 |
| 10,000 | CURRENT-N | B | 124.283 | 124.047–126.540 | 13 / 18 | 2,021,978 | 0.501 | 0.903 |
| 10,000 | CURRENT-N | C | 62.587 | 61.908–63.591 | 5 / 18 | 2,018,366 | 0.500 | 0.455 |
| 10,000 | MONOLITHIC-N | full | 136.733 | 136.060–138.027 | 1 / 1 | 4,359,559 | 1.000 | 1.000 |
| 10,000 | MONOLITHIC-N | A | 101.130 | 100.769–101.819 | 1 / 1 | 4,359,559 | 1.000 | 0.740 |
| 10,000 | MONOLITHIC-N | B | 132.567 | 132.395–134.244 | 1 / 1 | 4,359,559 | 1.000 | 0.970 |
| 10,000 | MONOLITHIC-N | C | 72.209 | 72.038–73.064 | 1 / 1 | 4,359,559 | 1.000 | 0.528 |
| 10,000 | SUBTREE-N | full | 137.601 | 137.168–138.686 | 22 / 22 | 3,078,201 | 1.000 | 1.000 |
| 10,000 | SUBTREE-N | A | 106.785 | 106.565–109.257 | 14 / 22 | 774,956 | 0.252 | 0.776 |
| 10,000 | SUBTREE-N | B | 212.457 | 212.172–220.023 | 15 / 22 | 1,542,075 | 0.501 | 1.544 |
| 10,000 | SUBTREE-N | C | 153.289 | 152.769–161.200 | 7 / 22 | 1,538,463 | 0.500 | 1.114 |
| 50,000 | CURRENT-N | full | 686.673 | 683.573–695.019 | 18 / 18 | 20,177,823 | 1.000 | 1.000 |
| 50,000 | CURRENT-N | A | 460.099 | 457.273–462.018 | 13 / 18 | 10,091,970 | 0.500 | 0.670 |
| 50,000 | CURRENT-N | B | 619.996 | 616.080–624.274 | 13 / 18 | 10,091,970 | 0.500 | 0.903 |
| 50,000 | CURRENT-N | C | 314.679 | 311.730–327.362 | 5 / 18 | 10,088,358 | 0.500 | 0.458 |
| 50,000 | MONOLITHIC-N | full | 678.986 | 676.859–685.958 | 1 / 1 | 21,779,543 | 1.000 | 1.000 |
| 50,000 | MONOLITHIC-N | A | 501.532 | 500.137–503.596 | 1 / 1 | 21,779,543 | 1.000 | 0.739 |
| 50,000 | MONOLITHIC-N | B | 665.330 | 661.466–676.610 | 1 / 1 | 21,779,543 | 1.000 | 0.980 |
| 50,000 | MONOLITHIC-N | C | 360.599 | 359.676–365.461 | 1 / 1 | 21,779,543 | 1.000 | 0.531 |
| 50,000 | SUBTREE-N | full | 680.681 | 679.319–682.133 | 22 / 22 | 15,378,185 | 1.000 | 1.000 |
| 50,000 | SUBTREE-N | A | 535.184 | 531.537–536.006 | 14 / 22 | 3,849,952 | 0.250 | 0.786 |
| 50,000 | SUBTREE-N | B | 1074.462 | 1070.449–1080.768 | 15 / 22 | 7,692,067 | 0.500 | 1.579 |
| 50,000 | SUBTREE-N | C | 775.688 | 770.793–777.205 | 7 / 22 | 7,688,455 | 0.500 | 1.140 |

### 50k partial stage medians (ms)

| Layout | Task | File read | JSON + typed decode | Closure / selection / reconstruction residual | Projection encode |
|---|---|---:|---:|---:|---:|
| CURRENT-N | A | 3.318 | 299.023 | 99.955 | 57.312 |
| CURRENT-N | B | 3.122 | 300.123 | 200.922 | 115.472 |
| CURRENT-N | C | 1.944 | 299.344 | 13.562 | 0.050 |
| MONOLITHIC-N | A | 4.557 | 340.429 | 102.028 | 54.246 |
| MONOLITHIC-N | B | 4.676 | 341.183 | 206.167 | 111.910 |
| MONOLITHIC-N | C | 3.480 | 343.823 | 13.435 | 0.057 |
| SUBTREE-N | A | 2.169 | 281.731 | 193.986 | 56.539 |
| SUBTREE-N | B | 3.509 | 563.248 | 392.563 | 115.338 |
| SUBTREE-N | C | 2.109 | 562.195 | 210.727 | 0.050 |

`fileReadMs` includes regular-file metadata checks and actual Data reads. `jsonAndTypedDecodeMs` includes raw JSON decode and typed-decode re-encoding. Residual subtracts measured non-overlapping read/decode/terminal encode spans from total and includes closure traversal, selection, JSON-value reconstruction and other uninstrumented work; it is not a pure graph-traversal measurement. Stage medians need not sum to the total median. Full open uses the same prior test-only read/decode/reconstruction/typed decode/full-validation pipeline, with stage raw samples retained.

## Interpretation

- CURRENT A/B read the entire selected Screen shard, about half the candidate bytes at 50k. C also reads the whole Screen but returns one small Layer payload and only its Scope closure.
- MONOLITHIC always opens/JSON-decodes the entire aggregate (byte fraction 1). Reduced payload/dependency work can still reduce total task time; this does not make the file IO partial.
- SUBTREE A reads 3,849,952 bytes / 15,378,185 total (~0.250), yet median 535.184 ms exceeds CURRENT A 460.099 ms. Lower read bytes do not establish faster read semantics in this prototype.
- SUBTREE B reads both selected subtrees and median 1,074.462 ms exceeds its full-open median 680.681 ms. The partial implementation re-encodes decoded Layer subtrees into a Screen JSON value, then typed-decodes that Screen before projection; the reconstruction/residual cost matters. Do not attribute this solely to filesystem sharding or claim production latency.
- SUBTREE C must open both child subtrees to locate the late Layer ID; no ID→subtree locator is available. Sharding alone does not provide targeted arbitrary Layer-ID lookup. A locator would be an additional implementation/consistency cost, not implemented here.
- Semantic slice bytes/closure can be useful independently of global validity. No partial result is a CanonicalSnapshot. The fingerprint and oracle checks are experiment controls, not permission to issue ProjectObservation, ClientPrecondition or mutation authority. Existing full authoring observation remains required.

## Failed attempts and reliability limits

[Failure data](partial-load-failures.json) retains both full initial attempts, including already-completed measured/warm-up samples. Attempt 1 stopped after 1k and 10k CURRENT timing because orchestration used a nonexistent `expected` helper argument. Attempt 2 corrected the argument name but assumed validation exit 3; actual Current load rejects invalid input first as storage exit 7. Accepted attempt 3 uses the actual parser error contract. No assertions, closure rules, sample counts or layout were weakened or tuned from performance results. Earlier attempts are not combined into the accepted matrix or silently discarded.

Each sample is streamed and persisted, including a series-complete source check. A process deadline kills a stalled child; errors/partial samples remain incomplete/failed. Preparation also records compiler failures if present. This run exercises failure retention through the two orchestration failures; it does not inject every OOM/timeout/cancellation or filesystem race.

Real AI total tokens, model cost, cold-cache performance, peak RSS, production partial-reader latency and concurrent snapshot guarantees are unmeasured. Byte counts/tool output are not token savings. Fixed task/layout order is not counterbalanced and one local environment is not a performance guarantee. No production Sources, Format, migration, Index, Preview or Package target changed.

## Routing

All planned correctness/source/completeness gates passed. Route: report for ADR Decision Review / possible Ready for Decision. Keep `Spike Required` until that review; do not select a layout from partial bytes or add a locator/production reader automatically. Merge behavior, replacement payload, 50k open/save and this read-only partiality evidence are available with their limits. Many-shard scaling, arbitrary-reference edits and coherent partial authoring remain unverified and must be bounded explicitly in any decision.

## Reproduce

```sh
python3 adr/git-canonical-sharding/spikes/shard-merge-benchmark/artifacts/measure-partial-load.py --output /tmp/partial-load-matrix.json
```

This rebuilds Release, links a disposable executable using the exact common helper prefix from `measure-open-save-scaling.swift`, creates fresh fixtures, validates each layout, records each sample/control and cleans temporary repositories. Raw timings and series are the evidence; summary ratios are deterministic postprocessing using Python `statistics.median`/`min`/`max`, excluding `warmup = true`. Source/binary/toolchain fingerprints must be compared before reusing results.
