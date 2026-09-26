# Canonical freshness 判定の cost 分解

## Related Decision

[Index consistency ADR](../../ADR.md) の安全な CanonicalRevision 計算と自動復旧方式。`CanonicalRevision` abstraction と具体的な計算 algorithm は独立に扱う。

## Hypothesis

**Unverified:** CLI query の p95 超過は SQLite の行検索より、Git working tree の freshness 判定または CLI 起動に支配される。安全な判定を維持したまま per-query cost を下げる余地がある。

## Questions

- Git status、tracked flags、filter attributes、dirty Canonical bytes の各 cost はどれだけか。
- CLI 起動、SQLite open/query、CanonicalRevision 計算の比率はどうか。
- watcher / cache / filesystem metadata を使う候補は、取りこぼし後にどう再同期し、Git filter や非協調 edit をどう検出するか。
- Working tree の Canonical bytes を実際に識別しつつ、全 JSON を毎 query 読まずに済むか。

## Prototype Scope

Starter Sample の実 working tree で 40 回の CLI query、CLI version、Git の各 command、SQLite read を独立に計測する。次段階では 100 / 1000 / 5000 shard と staged / unstaged / untracked / filtered 状態を分け、候補 algorithm を同じ correctness oracle で比較する。

## Out of Scope

安全性を弱めた高速化、計測前の algorithm 決定、automatic recovery の production 実装。

## Measurements

実行環境、Sample の Git state、shard 数、各操作の raw wall time、nearest-rank p50/p95、SQLite file size。独立 subprocess の時間を足して CLI 内訳とみなさない。

## Success Criteria

安全な現行 query の cost hotspot を特定し、候補の correctness test に Git filter / hidden flags / external edit を含める。性能比較は同一 fixture と条件で行う。

## Failure Criteria

計測条件が曖昧、独立 subprocess の時間を CLI 内訳と誤認する、または stale result を許す案を採用する。

## Result

**Measured, Starter Sample only:** macOS 26.2、Apple Git 2.50.1、Swift 6.4 debug binary、Canonical JSON 8 files、tracked Canonical paths 8、SQLite 40 KiB、manifest revision 22（作業ツリーで manifest 変更あり）の条件で独立操作を各 40 回計測した。nearest-rank p95 は CLI `version` 5.754 ms、CLI `query components` 305.880 ms、`/usr/bin/git status` 18.794 ms、`ls-files -v` 14.344 ms、`check-attr filter` 13.752 ms、Python SQLite open/metadata/component query 0.142 ms。これらは別 subprocess の wall time であり、足し算して CLI の内訳とはできない。今回の CLI query は 250 ms 比較基準を超えた。Starter に ComponentDefinition はなく query hit は空である。

**Measured, temporary in-process instrumentation:** 同じ CLI query path の別 run 20 回で `GitCanonicalRevisionCalculator` 内の各 Git `Process.run` から output read / wait までを測った。p95 は status 99.041 ms、flags 100.079 ms、filter attributes 105.791 ms、残りの revision parse/hash 1.017 ms、CLI 全体 327.946 ms。各 Git subprocess の起動・pipe・待機を含む計測であり、3 subprocess がこの fixture の query latency の主因と推定できる。1 回の CLI outlier は 807.699 ms。instrumentation は測定後に production source から除去した。独立操作と in-process の Git 時間差の詳細な OS 要因は未特定。

**Measured after branch-switch guard:** 最初と最後の Git status output を照合する安全ガードを追加した後、同じ Starter Sample と 40 回の独立操作計測を再実行した。CLI query p95 は 404.611 ms、p50 は 374.476 ms。別 run のガード前 p95 305.880 ms と比べると約 99 ms 高いが、独立 run 間の差を厳密な追加 call cost とみなさない。`version` にも最大 399.742 ms の外れ値があり、環境ノイズがある。新しい in-process breakdown は未測定。250 ms 比較基準は依然超過する。

**Not measured in this cost profile:** dirty shard / filtered path が多い規模、低 cost 候補の correctness、watcher 再同期、concurrent Git mutation、automatic recovery。branch switch の 1 条件は [Concurrent Git mutation Spike](../concurrent-git-mutation/SPIKE.md) で別に検証した。

## Conclusion

この Starter 条件では SQLite 行読み取りより Git subprocess を複数回呼ぶ CanonicalRevision 計算が支配的だった。branch-switch の既知の race を拒否する追加 status guard 後は query p95 が約 405 ms となった。`CanonicalRevision` の抽象契約は保持し、計算 algorithm を確定しない。安全で低 cost な実装方式と自動復旧方式は **Unknown**。Index ADR は未解決。

## Artifacts

- [profile.py](artifacts/profile.py): CLI、Git、SQLite の独立操作を 40 回ずつ計測する再現 script。
- [result-before-second-status.json](artifacts/result-before-second-status.json): branch-switch guard 前の条件と各操作の raw wall time。
- [result.json](artifacts/result.json): branch-switch guard 後の条件と各操作の raw wall time。
- [in-process-result.json](artifacts/in-process-result.json): 一時的な calculator 内計測の raw wall time。Status、flags、attributes の Git call 境界と parse/hash 終端を測定した。計測コードは production に残さない。
