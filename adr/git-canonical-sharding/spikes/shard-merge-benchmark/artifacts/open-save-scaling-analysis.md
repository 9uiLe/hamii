# Serializer control and Release open/save scaling

## Conditions

Precommitted plan: `5434a3ebe03982bf7644380b20cad0582dff70a5` ([Verify](https://github.com/9uiLe/hamii/actions/runs/36661867061)). [Raw matrix](open-save-scaling-matrix.json) records source/toolchain/SDK/platform, compiler command, Release object/prototype/binary fingerprints, environment load, every control merge and sample. Production source, Package and dependency lock are unchanged. No production target imports these artifacts.

Environment: macOS 27 arm64, Swift 6.4, SDK 27.0, Git 2.52.0, 10 logical CPUs. Release modules are built with `swift build -c release --product hamii`; the test-only executable links HamiiCore/Application/Format Release objects with `swiftc -O -swift-version 6 -target arm64-apple-macosx14.0`. Sequential 1k/10k/50k order and CURRENT-N/MONOLITHIC-N/SUBTREE-N order, local warm filesystem, one open warm-up per measured API/layout. No competing full gate; layout order is fixed rather than counterbalanced. No cold-cache claim.

Each scale has exactly the planned Layer count, two Screens, four child Stack subtrees, two Component roots and the same Scope/Component/Token/AppSurface/Target semantics. Path counts remain 13/1/17 across scales: this tests increasingly large payloads, not a large number of shards or arbitrary project structure.

## Serializer control

All normalized candidates use one Swift/Foundation JSONSerialization implementation with sorted keys, pretty printed, unescaped slashes and trailing LF. CURRENT-P preserves actual production bytes. CURRENT-N is the current layout through the common encoder. MONOLITHIC-N/SUBTREE-N retain the prior fixed aggregate boundaries; Python transports raw/base64 bytes and orchestrates, but does not serialize measured candidates.

1k and 10k CURRENT-P/N baseline inventories and equal-length Text replacement bytes are exactly equal in these fixtures. This does not promise byte equality for arbitrary JSON values/projects.

| Layers | CURRENT-P/N baseline bytes | CURRENT-P/N replacement bytes |
|---:|---:|---:|
| 1,000 | 406,265 | 201,642 |
| 10,000 | 4,033,265 | 2,015,142 |

At 10k, five scenarios × four layouts × one repetition gave 20 control merges, 60 base/A/B current-format validations and 12 clean semantic-preserving merge validations. All three independent edit scenarios were clean; same-property and same-parent append conflicted in all four layouts. CURRENT-P/N classifications matched, including append. This is a correctness/qualitative control, not a new conflict-frequency benchmark.

The prior [Python-encoder results](save-merge-analysis.md) remain unchanged. Their normalized replacement values differ: at 10k, MONOLITHIC 3,624,431 → MONOLITHIC-N 4,354,388 bytes; SUBTREE 665,309 → SUBTREE-N 767,764 bytes. The prior byte magnitudes and marker shapes are serialization-sensitive. This control preserves the tested qualitative clean/conflict classification; it does not make all earlier ratios granularity-only effects.

## Actual production API measurements

Ten load/observe samples per scale; five fresh-copy mutation samples. Cells are median (min–max) milliseconds. Timing starts at the public API call and stops at its return; OS process launch, fixture preparation, Git commit and post-result correctness checks are excluded.

Load and observe are separate; observe includes production ClientPrecondition work. Save is `ProjectService.mutate(.setText, expectedState:, author:.human)`, including its internal observation, semantic validation, Canonical commit/journal/generation coordination and returned new precondition. Each fresh copy is observed before timing, then makes the same eight-character Text edit; the resulting Document must equal the MutationEngine’s exact expected delta. These are production API measurements, not CLI latency or end-to-end application/AI cycle latency.

| Layers | load, n=10 ms | observe, n=10 ms | mutation save, n=5 ms |
|---:|---|---|---|
| 1,000 | 8.456 (8.376–8.803) | 9.556 (9.432–9.761) | 54.767 (54.239–59.846) |
| 10,000 | 76.317 (76.062–77.548) | 79.812 (79.287–81.370) | 432.247 (431.080–435.381) |
| 50,000 | 381.717 (380.050–432.933) | 394.700 (392.264–402.488) | 2134.925 (2124.024–2139.140) |

## Normalized prototype measurements

Prototype open performs candidate file read, JSON-value decode, layout reconstruction, common typed-current decode/Document construction and DocumentValidator. The typed-current stage re-encodes JSON values into Data before decoding Current entity types; all three layouts pay that extra work. It is not the production loader, and the prototype vs production timing gap is not a measured optimization opportunity.

Prototype save starts with the same in-memory semantic delta, encodes the complete candidate inventory and writes only changed files. Each sample uses a fresh copy. There is no journal, generation protocol, durability/fsync or production save machinery. Replacement bytes are changed serialized payload, not physical/durable IO. No speedup ratio against production save is claimed.

Ten prototype open and five prototype save samples per cell; median (min–max) milliseconds.

| Layers | Layout | open ms | encode/delta ms | write ms | total prototype save ms | Replacement bytes |
|---:|---|---|---|---|---|---:|
| 1,000 | CURRENT-N | 16.039 (15.979–16.380) | 10.239 (10.164–10.421) | 0.452 (0.383–0.943) | 10.667 (10.587–11.225) | 201,642 |
| 1,000 | MONOLITHIC-N | 14.628 (14.480–14.895) | 10.215 (10.196–10.479) | 0.350 (0.283–0.811) | 10.547 (10.495–11.292) | 439,388 |
| 1,000 | SUBTREE-N | 16.658 (16.524–17.106) | 10.308 (10.267–10.668) | 0.422 (0.398–0.853) | 10.781 (10.738–11.224) | 77,014 |
| 10,000 | CURRENT-N | 137.814 (137.109–138.675) | 101.501 (101.120–103.130) | 1.769 (1.711–2.043) | 103.380 (102.974–105.312) | 2,015,142 |
| 10,000 | MONOLITHIC-N | 136.588 (135.970–139.167) | 102.996 (101.976–105.711) | 2.465 (2.173–2.770) | 105.427 (104.493–108.490) | 4,354,388 |
| 10,000 | SUBTREE-N | 136.788 (135.955–138.039) | 100.982 (100.829–101.741) | 1.262 (0.942–2.995) | 102.383 (102.149–103.960) | 767,764 |
| 50,000 | CURRENT-N | 683.863 (679.647–691.200) | 513.874 (513.406–520.428) | 3.777 (3.701–4.282) | 518.670 (518.317–526.348) | 10,085,134 |
| 50,000 | MONOLITHIC-N | 684.225 (680.551–687.386) | 514.896 (514.729–518.498) | 9.796 (9.617–11.308) | 525.956 (524.358–528.438) | 21,774,372 |
| 50,000 | SUBTREE-N | 678.285 (677.409–683.372) | 511.716 (509.693–517.511) | 2.788 (2.248–3.618) | 515.937 (513.188–521.583) | 3,842,760 |

All candidate inventories are serialized before the changed-file filter. The tested smaller SUBTREE replacement payload therefore does not proportionally reduce prototype encode cost. Prototype write cost is warm buffered file write; its small size is not evidence for production durable IO cost.

## Metadata and stages

| Layers | Layout | Paths / files read | JSON / bytes read | Largest shard | Median shard |
|---:|---|---:|---:|---:|---:|
| 1,000 | CURRENT-N | 13 | 406,265 | 200,997 | 283 |
| 1,000 | MONOLITHIC-N | 1 | 439,388 | 439,388 | 439,388 |
| 1,000 | SUBTREE-N | 17 | 310,795 | 76,369 | 524 |
| 10,000 | CURRENT-N | 13 | 4,033,265 | 2,014,497 | 283 |
| 10,000 | MONOLITHIC-N | 1 | 4,354,388 | 4,354,388 | 4,354,388 |
| 10,000 | SUBTREE-N | 17 | 3,073,795 | 767,119 | 524 |
| 50,000 | CURRENT-N | 13 | 20,173,249 | 10,084,489 | 283 |
| 50,000 | MONOLITHIC-N | 1 | 21,774,372 | 21,774,372 | 21,774,372 |
| 50,000 | SUBTREE-N | 17 | 15,373,779 | 3,842,115 | 524 |

50k prototype open stage medians (ms). These are disjoint stage intervals; total remains the independently timed open call and includes bookkeeping between stages.

| Layout | read | JSON decode | reconstruct | typed decode / re-encode | validation |
|---|---:|---:|---:|---:|---:|
| CURRENT-N | 5.360 | 87.385 | 0.120 | 509.382 | 80.694 |
| MONOLITHIC-N | 3.803 | 89.946 | 0.182 | 508.622 | 80.614 |
| SUBTREE-N | 5.113 | 82.777 | 0.448 | 509.698 | 80.297 |

Actual production syscall/file read counts are unmeasured: the public Release API has no recording seam and production was not changed for this prototype. Canonical inventory sizes above are not inferred production read counts. Peak RSS is unmeasured; no dependency, instrumentation or resource claim is introduced.

## Correctness, failures and claim limits

All three scales/layouts completed three deterministic encode/decode/reconstruct/actual-current-parser round trips (27), ten typed/validated opens (90) and five fresh encode/write results with exact expected deltas and actual Current parser validation (45). Production returned exact baseline/result Documents across 60 measured load/observe calls and 15 fresh-copy saves. Negative dangling/duplicate/unreachable/unknown/mismatched subtree probes passed at all scales, including 50k. No measured OOM/crash/timeout or incomplete scale was omitted.

An initial prototype compile failed on Swift 6 actor isolation for a global FileManager. [Preparation failure](open-save-preparation-failures.json) retains the source fingerprint and diagnostic; replacing the global with local FileManager values preserved Swift 6 checking. It occurred before measured trials. The earlier [fixture preparation failure](save-merge-initial-failure.json) remains unchanged too.

An interrupted or failed case is retained as incomplete/failed in the top-level matrix, with stderr/exit status where available; the Swift per-scale samples are emitted at case completion, so an abrupt stop before that point does not preserve inner-operation timings. Such a case never supplies successful samples or a complete-series claim.

No p95, Product SLA, measured throughput, arbitrary project scalability, winning format or production speedup is inferred from these ten/five samples. AI total tokens, LLM task success, costs, peak RSS, production syscall counts, cold-cache behavior, many-shard scaling and full application/development-cycle performance remain unmeasured.

## Result and next routing

Confirmed for tested fixtures: common encoder control preserves qualitative classification; all candidates retain semantic data, reconstruct current valid Documents and have deterministic bytes through 50k. Measured: production 50k load/observe/mutation save medians are 381.717/394.700/2,134.925 ms. Normalized layout opens and encodes are similar under the common full-inventory pipeline; SUBTREE replacement payload is smaller, but whole-inventory encode work and durability boundaries remain separate.

Precommitted route: **50k viable → partial-load Evidence next**. The sharding ADR remains **Spike Required**. No production partial reader or format migration is authorized by these timings; do not move to Ready for Decision before partial-load Evidence and review.

## Reproduction

```sh
python3 adr/git-canonical-sharding/spikes/shard-merge-benchmark/artifacts/measure-open-save-scaling.py --output /tmp/hamii-open-save.json
```

The orchestrator builds Release, compiles the isolated Swift probe, checks source/Package/lock cleanliness, runs the serializer gate before creating 50k, and retains failures. Use the recorded compatible macOS/Swift environment and no competing full gate. The first qualitative control is one repetition; production/prototype timing counts remain fixed at ten/five. Success requires both raw experiment completeness and the Evidence commit’s local full gate / exact-SHA Verify.
