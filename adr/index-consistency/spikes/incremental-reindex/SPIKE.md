# Incremental reindex と atomic generation publish

## Related Decision

[Index consistency ADR](../../ADR.md) の自動復旧方式と index generation 公開境界。

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

**Measured, conceptual prototype only:** synthetic dependency graph と SQLite WAL で、Token → alias → Component → Screen、Component → Component → Screen、Scope → descendant Scope → Component → Screen の 3 変更を試した。reverse dependency closure で affected nodes を選び、staging generation を transaction 内に作った。別 reader は commit 前に新しい Canonical source identity を渡すと `stale` を返し、commit 後は新 generation の全行が full rebuild oracle と一致した。rollback 後も新 source に対して `stale` だった。各 stage の時間は 0.072〜0.114 ms だが、この小さな合成 graph の値は production latency を示さない。**Not implemented / not measured:** 実際の HamiiIndex schema、Canonical parser、entity 削除・rename、component availability / usage の実データ、同時 Git 操作、大規模 Project。

**Inferred from current production code, not measured:** `IndexProjection` の現在の行依存を [inventory](artifacts/current-projection-dependencies.md) に整理した。`usage_count` は Screen layer tree、`scope_closure` は Scope ancestry、`component_availability` は Scope と ComponentDefinition の nested dependency を参照する。現在の SQLite schema に Token / Asset usage index はないため、合成 Token graph の成立を現行 HamiiIndex の検証結果へ広げない。

## Conclusion

reverse dependencies と atomic generation publish の組は小さな合成 graph で成立した。**Unknown:** 実際の hamii derived indexes と source snapshot の下で同じ correctness を保てるか。自動復旧方式は ADR で未決定。

## Artifacts

- [probe.py](artifacts/probe.py): 合成依存 graph と SQLite WAL generation の概念検証。
- [result.json](artifacts/result.json): affected nodes、公開前後の query outcome、oracle 比較。
- [current-projection-dependencies.md](artifacts/current-projection-dependencies.md): production code から導いた現行 projection の依存 inventory。実測ではない。

実際の HamiiIndex schema / Canonical Format を用いる probe は未作成。
