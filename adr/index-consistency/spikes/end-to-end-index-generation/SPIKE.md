# CanonicalSnapshot から最初の Query までの Index pipeline

## Related Decision

[Index consistency ADR](../../ADR.md) の safe recovery と end-to-end cost。Snapshot guarantee は [CanonicalSnapshot Spike](../consistent-canonical-snapshot/SPIKE.md)、fast/slow freshness は [Fast-path Spike](../safe-freshness-fast-path/SPIKE.md) に依存する。

## Hypothesis

**Tentative:** Starter 条件では Projection / SQLite write より Canonical source observation / freshness が pipeline latency を支配する。`CanonicalSnapshot → derive CanonicalRevision → invalidate → project → stage IndexGeneration → validate → publish → first query` の一続きで測らない限り、自動復旧方式の性能は判断できない。

## Questions

- Safe CanonicalSnapshot acquisition、revision derivation、changed entity detection のそれぞれの p50/p95 はいくつか。
- Full / incremental projection、SQLite write、generation validation、atomic publication、first query を同一 run で分解できるか。
- Source が build 中に変わった場合、generation を破棄し、古い generation を stale として扱えるか。
- Cold/warm、small/medium/large、many shards / large file / dirty tree で cost の主因は変わるか。
- CLI 起動、Git subprocess、Canonical parser、SQLite I/O の内訳はどうか。

## Prototype Scope

まず current production full rebuild path を disposable Starter copy で in-process 計測し、既存の CLI fresh/stale/rebuild 測定と比較する。次段階で Snapshot acquisition の保証を選ぶ前に、候補ごとの end-to-end pipeline を同じ fixture で測る。実 `IndexProjection` と generation prototype を接続し、source-change barrier と first query まで計測する。

## Out of Scope

Partial timings を production end-to-end 性能とみなすこと、Snapshot / CanonicalRevision algorithm / recovery UX の採用、未検証の automatic recovery を production へ追加すること。

## Measurements

最低限 p50/p95 と raw samples: snapshot acquisition、revision determination、invalidation、projection、SQLite write、validation、publication、first query、total。CLI と in-process を区別し、file count / bytes / branch state / tracked/dirty/untracked / toolchain を残す。250 ms は現時点の比較基準であり Product SLA ではない。

## Success Criteria

同一 source snapshot から完全な generation を作り、公開前は source が変われば stale、公開後は最初の query が新 generation だけを見る。Full / incremental の総時間と内訳を同じ条件で比較し、p95 の遅い段階を特定する。

## Failure Criteria

別 source の行を混ぜる、中間 generation を見せる、source change 後に旧行を current と返す、または partial timings を足して end-to-end result と偽る。

## Result

**Measured, current full path only:** [EndToEndIndexSpikeTests.swift](../../../../Tests/HamiiTests/EndToEndIndexSpikeTests.swift) は disposable Starter copy（8 Canonical JSON、独立 Git repository、macOS 26.2 arm64、Swift 6.4 debug XCTest）で15回、`preRevision → CanonicalRepository.load → postRevision → IndexProjection → LocalIndex.rebuild → publish verification → first LocalIndex query` を同じ process で計測した。各行は nearest-rank p50 / p95 ms。`IndexProjection` は測定用に別途呼んでいるため `rebuild` 内でも再計算され、total には二重計算がある。`rebuildAggregate` は projection + SQLite write/commit を含み、純粋な SQLite write ではない。`canonicalLoad` は coordinated lock 下の load であり、external writer に対する一貫した `CanonicalSnapshot` の取得時間ではない。

| Stage | p50 / p95 ms |
| --- | ---: |
| Pre-revision verification | 378.89 / 430.52 |
| CanonicalRepository.load | 4.94 / 28.39 |
| Post-revision verification | 369.69 / 410.09 |
| Separate full IndexProjection | 0.04 / 0.18 |
| LocalIndex.rebuild aggregate | 1.42 / 3.85 |
| Post-rebuild source verification | 389.60 / 473.56 |
| First query after publication | 374.66 / 405.58 |
| Pipeline total | 1533.30 / 1604.51 |

Stage p95 values are not additive. Four revision calculations occur in this deliberately conservative rebuild/query path. In this fixture they account for most observed wall time; OS/process-start cause is not fully isolated. Current `LocalIndex.rebuild` commits before the final source verification; a mismatch then causes stale rejection but may leave an already-written, non-current index on disk. A new generation candidate must validate before atomic publication. The separate disposable Starter CLI profile measured fresh query p95 418.61 ms, stale detection p95 424.17 ms, and full rebuild p95 1316.33 ms. Those CLI runs have different boundaries and must not be combined arithmetically with this table. The [real projection generation prototype](../incremental-reindex/SPIKE.md) measured 1000-component full/partial SQL staging separately, but omits Canonical read, revision and projection; it is not an incremental end-to-end result.

**Unknown / not implemented:** safe CanonicalSnapshot acquisition, pure SQLite write and atomic publish timing from production code, stored dependency invalidation cost, first query after a production incremental generation, external Git mutation during build, warm/cold/large-project matrix. Current `LocalIndex` performs transactional full replacement and has no explicit generation ID or automatic recovery.

## Conclusion

この Starter / current path 条件では revision verification が latency の主因である可能性が高い。ただし Snapshot boundary を確立する前に calculator の高速化だけを選ばない。Safe snapshot と candidate generation を接続した full / incremental end-to-end comparison は未完了であり、Index ADR は未解決。

## Artifacts

- [EndToEndIndexSpikeTests.swift](../../../../Tests/HamiiTests/EndToEndIndexSpikeTests.swift): current full pipeline の in-process timing test。`HAMII_E2E_SPIKE_RESULT=/tmp/hamii-e2e-index-result.json swift test --filter EndToEndIndexSpikeTests` で再測定できる。
- [current-full-pipeline-result.json](artifacts/current-full-pipeline-result.json): raw timings と環境・limitation。
