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

Starter Sample の実 working tree で 40 回の CLI query、CLI version、Git の各 command、SQLite read を独立に計測する。次段階では disposable Git fixture の 8 / 100 / 1000 / 5000 Canonical JSON shard で候補 algorithm を同じ correctness oracle と in-process benchmark で比較する。Spike prototype は production module に追加しない。

## Out of Scope

安全性を弱めた高速化、計測前の algorithm 決定、automatic recovery の production 実装。

## Measurements

実行環境、Sample の Git state、shard 数、各操作の raw wall time、nearest-rank p50/p95、SQLite file size。独立 subprocess の時間を足して CLI 内訳とみなさない。

## Success Criteria

安全な現行 query の cost hotspot を特定し、候補の correctness test に Git filter / hidden flags / external edit を含める。性能比較は同一 fixture と条件で行う。

## Failure Criteria

計測条件が曖昧、独立 subprocess の時間を CLI 内訳と誤認する、または stale result を許す案を採用する。

## Result

### 候補の correctness contract

候補が `CanonicalRevision` として使える最低条件は、hamii が読む Canonical path と bytes が変わったら **異なる identity または明示的な拒否**を返し、検証不能な状態を current として返さないことである。Staged / unstaged / untracked shard、branch switch、Git clean filter、hidden flags、同じ size で mtime が復元された編集を含む。Canonical bytes が同じまま関係ない Git commit だけが増えた場合、同じ identity を返すのが不要な index rebuild を避けるうえで望ましい。これは correctness の必須条件とは分ける。

| Candidate | 成立に必要な条件 | この Spike で見えた限界 |
| --- | --- | --- |
| 現行 `guarded-git` | clean tracked content と working Canonical bytes の対応を確認し、hidden flags / filter を拒否し、前後の Git status を照合する | unrelated commit でも HEAD OID が変わり保守的に失効。最後の照合後の外部書込を防げない。ほかの Git attributes / 同時操作の完全な検証はない |
| 試作 `double-byte-scan` | Current loader と同一の Canonical path 集合を列挙し、実際に読む bytes を識別し、読めない file / symlink を拒否する | **二重走査だけでは false negative がある。** 2回の digest が一致しても一貫した複数 file snapshot とは限らない。多数 shard の cost も高い |
| 試作 `size-mtime` | size / mtime がすべての bytes 変更を識別する必要がある | 同サイズ編集後に mtime を元へ戻すと identity が変わらない反例。単独の freshness 判定には不適格 |

**Confirmed in disposable sequential fixtures:** 8 shard の各独立 Git Repository で、外部の同サイズ編集、staging、untracked Canonical shard、branch switch は3候補とも identity 変更を観測した。`assume-unchanged` edit と clean filter に隠された edit では現行方式は拒否し、double-byte-scan は bytes 変更を観測した。clean filter fixture で `git status --porcelain` は空だった。同サイズ編集後に mtime を復元した fixture では `size-mtime` の identity が同じままだった。関係ない非 Canonical file の commit では現行方式だけが identity を変えた。Canonical file を symlink に置換した場合は3候補とも拒否した。`changed` は candidate revision の差であり、index generation / query の end-to-end correctness 証明ではない。

**Measured in-process, optimized Swift 6.4 prototype:** macOS 26.2 arm64、Git 2.52.0、すべて tracked の小さな JSON shard を新規 temporary Git Repository に作成した。production の `GitCanonicalRevisionCalculator.swift` をそのまま compile し、同一 process 内で候補順を回転させて測定した。表は nearest-rank p50 / p95、単位 ms。`dirty` は tracked の10%を編集し、`untracked` は tracked 1000 個に100個を追加した。値は各候補の revision 計算のみで、CLI 起動 / SQLite query / index rebuild は含まない。

| Canonical JSON | runs | guarded-git | double-byte-scan | size-mtime |
| --- | ---: | ---: | ---: | ---: |
| 8 clean | 40 | 357.18 / 410.47 | 1.53 / 3.67 | 0.67 / 1.32 |
| 100 clean | 25 | 362.40 / 401.39 | 27.26 / 47.61 | 12.19 / 25.83 |
| 1000 clean | 15 | 365.79 / 376.60 | 339.26 / 368.45 | 154.97 / 173.60 |
| 1000, 10% dirty | 10 | 376.77 / 384.07 | 341.64 / 354.52 | 155.42 / 174.40 |
| 1000 + 10% untracked | 10 | 367.50 / 699.52 | 300.52 / 319.47 | 129.85 / 136.16 |
| 5000 clean | 6 | 367.32 / 373.98 | 1524.12 / 1575.92 | 694.52 / 701.19 |

各 file は約16 bytes で、5000 shard の Canonical bytes 総量は約80 KiB。double-byte-scan の大規模 cost は payload 容量だけでなく file 列挙 / open / read 回数の影響を受けると **推論**できるが、syscall 単位の profile は未実施。1000 の untracked 結果が clean より速いことを一般的性能傾向とはみなさない。連続した別 run でも値が揺れたため、単一条件の数 ms 差を候補間の優劣とみなさない。5000 の p95 は6回測定の最大値であり、分布推定として弱い。250 ms は既存の **CLI query** 比較基準なので、この in-process 値と同一指標として合否判定しない。

**Confirmed, loader path comparison:** Earlier `double-byte-scan` prototype recursively enumerated `*.json`, while `CanonicalRepository.readAll` loads only direct children of each canonical directory. The prototype was changed to direct children, then rebuilt and rebenchmarked in the table above. On a disposable copy of Starter, adding `components/nested/ignored.json` changed neither the actual `hamii inspect --json` Document nor the revised scan identity; adding `components/direct.json` changed the scan identity. This verifies those two path cases, not symlink handling, enumeration races, or complete loader parity.

**Failure Evidence, deterministic two-file concurrent-write counterexample:** After reading A=0 in each pass, a test hook writes A=1 then B=1, so each pass reads A=0/B=1. Between passes it resets B=0 then A=0. Both complete-scan digests match, yet A=0/B=1 never existed as a complete filesystem state, and the accepted digest differs from the final bytes. Thus repeated full reads with equal digests cannot be adopted as the multi-file snapshot guarantee. This is a Snapshot Boundary failure, not a single hash implementation bug. The hook is spike-only; no production calculator change was made.

**Measured, CLI end-to-end on a disposable Starter copy:** macOS 26.2 arm64、Swift 6.4 debug CLI、8 Canonical JSON、空の component hits。40 fresh queries の p50 / p95 は **352.50 / 418.61 ms**、20 stale query rejections は **396.05 / 424.17 ms**、20 full `hamii index rebuild` は **1198.87 / 1316.33 ms**。独立した Git repository に copy し、stale は tracked page JSON への外部 whitespace edit で作った。250 ms は比較基準であり製品 SLA ではない。これらは CLI 起動・Git verification・SQLite 等を含む wall time で、上表の in-process revision cost とは別指標である。

**Fast / slow path assessment:** `size-mtime` は高速だが restored mtime edit を current と誤認するため、単独の fast-path `certainly current` 条件にはできない。二重 bytes 走査は filter / hidden flag に隠れた実 bytes を読むが、上記の同時書込反例がある。現行 Git guard はテストした変更を検出または拒否するが、無関係な HEAD change で false-positive invalidation し query cost が高い。Watcher / cache / metadata の組合せで false negative なしに fast-path `yes` を出せる条件は **Unknown**。不確実なら slow verification または stale 拒否とする safety baseline を維持する。`CanonicalRevision` は hamii Canonical Data の状態、`IndexGeneration` は公開された derived snapshot の番号であり別概念。現行 HEAD OID を含む計算は Canonical file 無変更の commit でも失効させるため改善対象であり、semantic requirement ではない。

**Unknown / not implemented:** coherent multi-file snapshot を得る protocol、最終 check 後の外部書込、watcher / cache 再同期、巨大 file を含む実 Project、path-scoped Git identity、safe fast path、candidate を query / index generation と接続した場合の end-to-end correctness。方式は未選定。

**Measured, Starter Sample only:** macOS 26.2、Apple Git 2.50.1、Swift 6.4 debug binary、Canonical JSON 8 files、tracked Canonical paths 8、SQLite 40 KiB、manifest revision 22（作業ツリーで manifest 変更あり）の条件で独立操作を各 40 回計測した。nearest-rank p95 は CLI `version` 5.754 ms、CLI `query components` 305.880 ms、`/usr/bin/git status` 18.794 ms、`ls-files -v` 14.344 ms、`check-attr filter` 13.752 ms、Python SQLite open/metadata/component query 0.142 ms。これらは別 subprocess の wall time であり、足し算して CLI の内訳とはできない。今回の CLI query は 250 ms 比較基準を超えた。Starter に ComponentDefinition はなく query hit は空である。

**Measured, temporary in-process instrumentation:** 同じ CLI query path の別 run 20 回で `GitCanonicalRevisionCalculator` 内の各 Git `Process.run` から output read / wait までを測った。p95 は status 99.041 ms、flags 100.079 ms、filter attributes 105.791 ms、残りの revision parse/hash 1.017 ms、CLI 全体 327.946 ms。各 Git subprocess の起動・pipe・待機を含む計測であり、3 subprocess がこの fixture の query latency の主因と推定できる。1 回の CLI outlier は 807.699 ms。instrumentation は測定後に production source から除去した。独立操作と in-process の Git 時間差の詳細な OS 要因は未特定。

**Measured after branch-switch guard:** 最初と最後の Git status output を照合する安全ガードを追加した後、同じ Starter Sample と 40 回の独立操作計測を再実行した。CLI query p95 は 404.611 ms、p50 は 374.476 ms。別 run のガード前 p95 305.880 ms と比べると約 99 ms 高いが、独立 run 間の差を厳密な追加 call cost とみなさない。`version` にも最大 399.742 ms の外れ値があり、環境ノイズがある。新しい in-process breakdown は未測定。250 ms 比較基準は依然超過する。

**Observed, nested Project false invalidation:** Starter Sample の Canonical files に Git 差分がない状態で、この Repository の ADR と source を 2 commit した。commit 前に再構築した Starter の Local Index に対する CLI query は exit 8 / `staleIndex` となり、`hamii index rebuild` 後は exit 0 に戻った。1 回の観測であり、stale data の返却ではない。現行 calculator は Repository HEAD OID を revision に含めるため、Canonical path 外だけを変更する commit でも index を保守的に失効させるとコードから推論できる。Canonical contents が同じ場合の低 cost かつ安全な同一性判定は未解決。

**Not measured in the Starter cost profile:** dirty shard / filtered path が多い規模、watcher 再同期、concurrent Git mutation、automatic recovery。branch switch の 1 条件は [Concurrent Git mutation Spike](../concurrent-git-mutation/SPIKE.md) で別に検証した。

## Conclusion

この Starter 条件では SQLite 行読み取りより Git subprocess を複数回呼ぶ CanonicalRevision 計算が支配的だった。branch-switch の既知の race を拒否する追加 status guard 後は query p95 が約 405 ms となった。Repository 内の別ファイルだけを commit しても現行 Index は保守的に失効した。候補比較では、全 bytes 走査は少数 shard で速いが 5000 shard では高 cost、二重走査だけでは concurrent write 下で false negative を防げず、size/mtime は逐次 edit さえ見逃す反例があった。`CanonicalRevision` の抽象契約は保持し、計算 algorithm を確定しない。安全で低 cost な実装方式と自動復旧方式は **Unknown**。Index ADR は未解決。

## Artifacts

- [profile.py](artifacts/profile.py): CLI、Git、SQLite の独立操作を 40 回ずつ計測する再現 script。
- [result-before-second-status.json](artifacts/result-before-second-status.json): branch-switch guard 前の条件と各操作の raw wall time。
- [result.json](artifacts/result.json): branch-switch guard 後の条件と各操作の raw wall time。
- [in-process-result.json](artifacts/in-process-result.json): 一時的な calculator 内計測の raw wall time。Status、flags、attributes の Git call 境界と parse/hash 終端を測定した。計測コードは production に残さない。
- [candidates.swift](artifacts/candidates.swift): optimized Swift の byte / metadata 候補と同一 process benchmark。現行 Git 候補は production source を直接 compile する。
- [compare.py](artifacts/compare.py): disposable Git fixture の correctness cases と shard 数別 benchmark。`swiftc -O Sources/HamiiIndex/CanonicalRevision.swift Sources/HamiiIndex/GitCanonicalRevisionCalculator.swift adr/index-consistency/spikes/low-cost-freshness/artifacts/candidates.swift -o /tmp/hamii-freshness-probe` の後、`python3 adr/index-consistency/spikes/low-cost-freshness/artifacts/compare.py /tmp/hamii-freshness-probe --swiftc swiftc` で再測定できる。Swift 6.4 toolchain を選択する。
- [candidate-results.json](artifacts/candidate-results.json): fixture ごとの比較結果と raw latency。
- [snapshot_probe.py](artifacts/snapshot_probe.py)、[snapshot-result.json](artifacts/snapshot-result.json): 実 `hamii inspect` と試作 path 規則の比較、および二重走査の制御された同時書込反例。
- [query_profile.py](artifacts/query_profile.py)、[query-profile-result.json](artifacts/query-profile-result.json): disposable Starter copy の fresh / stale CLI query と full rebuild の raw wall time。
- [candidate-evaluation.md](artifacts/candidate-evaluation.md): correctness、false negative / positive、query/rebuild cost、Git 操作、scaling、complexity と fast/slow path の比較。
