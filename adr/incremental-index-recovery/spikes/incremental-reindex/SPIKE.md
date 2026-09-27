# Incremental reindex と atomic generation publish

## Related Decision

[Incremental Index Recovery ADR](../../ADR.md) の targeted projection と Index generation 公開境界。Automatic full rebuild の recovery policy は [Current Architecture](../../../../docs/final-architecture.md) に記載する。

## Hypothesis

**Inferred, unverified:** changed entity から reverse dependencies をたどって affected derived indexes を再生成し、完成した generation だけを atomic に公開すれば、full rebuild より少ない作業で fail-closed consistency を保てる。

## Questions

- Component、Scope、Token、Asset、Screen の変更・削除・rename は、どの reverse dependencies と derived indexes を無効化するか。
- 変更ファイルの検出と Canonical Document の読み取りが同じ source snapshot に属することをどう確認するか。
- generation 作成中・失敗時・公開直前後に query は何を返すか。
- full rebuild より速い規模と変更率はどこか。

## Prototype Scope

実際の Canonical Format と LocalIndex の代表的な entity / dependency を使う。`changed entity → reverse dependencies → affected derived indexes → staging generation → atomic publish` を一続きで試す。追加、更新、削除、scope promotion、token alias、component instance usage を含める。reader を各 barrier で走らせ、旧 generation を current と誤認しないことを確認する。

## Out of Scope

Spike prototype の production 採用、自動復旧の UX 決定、index を Canonical Data にする変更。

## Measurements

affected entity の正解集合と実際の invalidation、full rebuild / incremental の p50/p95、generation 作成・公開時間、追加 storage、barrier ごとの query outcome。規模と変更率を固定し raw data を残す。既存 CLI query p95 250 ms budget を比較軸にする。

## Success Criteria

代表的な変更で reverse dependencies と affected derived indexes に欠落がなく、公開途中の generation を読んだ query が 0 件、stale result を current と返す query が 0 件。失敗・source 変更時は旧 index を current と扱わず検索拒否へ戻る。

## Failure Criteria

依存 index の更新漏れ、部分公開、generation と Canonical source の対応不明、または失敗後に stale result を返す。

## Result

**Confirmed, actual `IndexProjection` and Canonical loader:** `IndexProjectionSpikeTests` builds valid `Document` fixtures, saves/loads one fixture through `CanonicalRepository`, and compares real `components` / `scope_closure` / `component_availability` rows with a full projection oracle. The spike-only invalidation planner selects affected row keys, copies old rows, replaces only selected keys from the new projection, and asserts exact equality to the full oracle. It tests five changes:

| Canonical change | Actual changed rows | Planned invalidation | Projection concern |
| --- | ---: | ---: | --- |
| Base component denies Product | 2 | 8 | availability for Base and reverse-dependent Wrapper |
| Checkout screen adds Base instance | 1 | 1 | Base component usage count |
| Checkout Scope parent moves | 2 | 7 | Checkout closure and availability |
| Other component name changes | 1 | 1 | Other component row |
| Spacing token value changes | 0 | 0 | none in the current query schema |

No changed row was omitted; every patched row set equaled the full `IndexProjection` result. The 8 / 7 planned rows are conservative recomputation within the affected projection, not evidence of a minimal row set. The current schema has no Token/Asset usage view. This planner is a test prototype; it obtains replacement values from a complete new `IndexProjection`, so it does **not** prove a fast incremental projector. Component deletion, scope subtree with descendants, slot-content dependency changes, and all future projections remain untested.

**Confirmed, spike-only atomic generation with actual projection rows:** A SQLite WAL prototype stores `source_canonical_revision` in `generations` separately from `active.generation` and stages rows copied from generation N plus affected-key replacements. Before commit, a second connection sees all of N when source A remains current; when the source is B it returns `stale`, never rows from the staged N+1. After validation and commit, source B reads all of N+1, equal to the full `IndexProjection` oracle. A failed stage or a source change before publication rolls back and retains N. A simulated source switch after a query reads rows returns `stale`. Partial-row observations in these deterministic barriers: **0**. This is an experimental generation schema, not `LocalIndex` production code. Current `LocalIndex.rebuild` writes all rows and metadata in one SQLite transaction but has no explicit `IndexGeneration` identifier.

**Confirmed, actual LocalIndex query:** A separate test builds an index on branch A, starts a query, switches to branch B after its SQLite row read and before its production `GitCanonicalRevisionCalculator` call, and observes `IndexError.stale` rather than an A hit. Both branches keep the same manifest revision and have different component bytes. This covers one deterministic interleaving; a switch after the final freshness check and arbitrary concurrent external writes remain unverified.

**Measured on one macOS 26.2 arm64 environment:** `IndexProjection` timings are Swift 6.4 debug XCTest in-process; generation timings are Python SQLite WAL in-process. Each cell is nearest-rank p50 / p95 ms. Generation timings exclude Canonical file loading, revision calculation, projection computation, CLI startup, and query freshness. The incremental prototype copies all prior rows before patching, so its cost still scales with total rows. This is a mechanism comparison, not an end-to-end recovery claim.

| Components / rows | Runs projection / SQL | Full projection | Full generation SQL | Incremental generation SQL |
| --- | ---: | ---: | ---: | ---: |
| 4 / 28 | 40 / 25 | 0.132 / 0.135 | 0.096 / 0.125 | 0.137 / 0.170 |
| 100 / 508 | 40 / 25 | 1.295 / 1.786 | 0.895 / 0.936 | 0.751 / 0.826 |
| 1000 / 5008 | 15 / 10 | 10.972 / 11.110 | 8.277 / 8.669 | 5.828 / 6.045 |

**Unknown / not implemented:** production changed-entity detection, stored reverse-dependency index, targeted projection recomputation, real Git mutation during generation build, source snapshot ownership across Canonical loader / revision calculator / Indexer, atomic generation schema in `LocalIndex`, recovery policy, and end-to-end full/incremental rebuild latency. `CanonicalRevision` describes source state; `IndexGeneration` describes a published derived snapshot. Neither can substitute for the other.

**Measured, separate conceptual prototype:** synthetic dependency graph と SQLite WAL で、Token → alias → Component → Screen、Component → Component → Screen、Scope → descendant Scope → Component → Screen の 3 変更を試した。reverse dependency closure で affected nodes を選び、staging generation を transaction 内に作った。別 reader は commit 前に新しい Canonical source identity を渡すと `stale` を返し、commit 後は新 generation の全行が full rebuild oracle と一致した。rollback 後も新 source に対して `stale` だった。各 stage の時間は 0.072〜0.114 ms。この合成 graph は上記の実 `IndexProjection` probe と独立であり、production latency は示さない。

**Inferred from production source inspection:** `IndexProjection` の現在の行依存を [inventory](artifacts/current-projection-dependencies.md) に整理した。`usage_count` は Screen layer tree、`scope_closure` は Scope ancestry、`component_availability` は Scope と ComponentDefinition の nested dependency を参照する。現在の SQLite schema に Token / Asset usage index はないため、合成 Token graph の成立を現行 HamiiIndex の検証結果へ広げない。

## Conclusion

Actual `IndexProjection` rows でも、検証した変更に対する invalidation set と staging / atomic publish の組は full projection oracle に一致した。実 `LocalIndex` query の branch switch 1 条件も stale として拒否した。**Unknown:** production incremental projector、Canonical files の一貫した source snapshot、Git 操作と generation build の競合、end-to-end cost。この Spike 実施時点では自動復旧方式は未決定だった。現在の判断状態は各 ADR に記録する。

## Artifacts

- [probe.py](artifacts/probe.py): 合成依存 graph と SQLite WAL generation の概念検証。
- [result.json](artifacts/result.json): affected nodes、公開前後の query outcome、oracle 比較。
- [current-projection-dependencies.md](artifacts/current-projection-dependencies.md): production code から導いた現行 projection の依存 inventory。実測ではない。
- [IndexProjectionSpikeTests.swift](../../../../Tests/HamiiTests/IndexProjectionSpikeTests.swift): 実 `IndexProjection` / Canonical loader / LocalIndex branch-switch query を検証する test source。
- [actual_projection_probe.py](artifacts/actual_projection_probe.py): 実 projection rows を使う generation staging / reader barrier / rollback / SQL benchmark。
- [actual-projection-result.json](artifacts/actual-projection-result.json): changed/invalidated row keys、atomic reader outcomes、raw p50/p95 timings。`HAMII_PROJECTION_SPIKE_RESULT=/tmp/hamii-projection-spike-result.json swift test --filter IndexProjectionSpikeTests` の後、`python3 adr/incremental-index-recovery/spikes/incremental-reindex/artifacts/actual_projection_probe.py /tmp/hamii-projection-spike-result.json /tmp/hamii-actual-projection-result.json` で再測定できる。

Actual projection rows を使う probe は実施済み。Production incremental reindexer / general atomic generation switch は未実装。Result 内の schema / type の現行形に関する記述は、この Spike を実行した時点の Evidence であり、現在の `LocalIndex` は `IndexGenerationID` と typed source binding を持つ。
