# Git mutation と reindex/query の競合

## Related Decision

[Index consistency ADR](../../ADR.md) の source snapshot、generation publish、fail-closed query protocol。

## Hypothesis

**Inferred, unverified:** Git checkout / pull / external edit が reindex と交錯しても、source identity を generation 作成前後に検証し、identity が不安定なら generation を current と公開せず query を拒否できる。

## Questions

- HEAD、index、working tree の更新途中に fingerprint がどの状態を返すか。
- `assume-unchanged`、Git filter、symlink、未追跡・ignored shard で変更を見落とすか。
- reindex と query の間、および query 中の外部 mutation をどの時点で stale と判定できるか。
- watcher を補助に使う場合、取りこぼし後に何で再同期するか。

## Prototype Scope

一時 Git repository と実際の Canonical JSON / index code を使い、barrier 付き checkout、pull、external edit、stage、rename、delete を query / full rebuild / incremental prototype の各段階へ注入する。競合時の結果を `current generation`、`staleIndex`、`retry` に分類する。`assume-unchanged`、filter、symlink は独立 scenario として測る。

## Out of Scope

hamii Canonical save と外部 writer の bytes 保護。その判断は [External Git Write ADR](../../../git-external-write-coordination/ADR.md) に属する。

## Measurements

各 interleaving の source identity、index generation、query outcome、stale result 数、拒否率、再試行回数、p50/p95 latency。barrier と random repeat の環境、seed、回数を記録する。

## Success Criteria

競合中または競合後に stale result を current と返す件数 0。判断不能な snapshot は fail closed。完了した mutation 後に正本から再構築できる。

## Failure Criteria

混在 snapshot の generation を current と公開する、Git の更新を見落として旧結果を返す、または競合後に再構築できない。

## Result

**Confirmed in regression replay:** Current production CLI on disposable repositories still returns exit 8 / `staleIndex` with no hits for Canonical component edits hidden by one Git clean filter, `assume-unchanged`, and `skip-worktree`. Rebuild also rejects the filter/flag states. This replays the sequential safety baseline; it does not establish general concurrent writer safety.

**Confirmed in actual LocalIndex query test:** `IndexProjectionSpikeTests.testActualIndexQueryRejectsBranchSwitchAfterReadingRows` switches from A to B inside the query's revision calculator call after SQLite rows were read. The old A hit is rejected with `IndexError.stale`; the Canonical loader observes B. Both branches have the same manifest revision. This is a separate interleaving from the prior switch between two Git status calls. An external switch after the final revision check remains untested. A spike-only generation prototype with real `IndexProjection` rows rolls back a staged generation when the source identity changes before publish; no production incremental reindexer exists.

**Measured, sequential Git index flags:** macOS 26.2 / Git 2.52.0 の一時 Repository で、tracked Component JSON に `assume-unchanged` または `skip-worktree` を付けて内容を変更すると、`git status --porcelain` は空になった。追加ガードの前には `assume-unchanged` で旧 Component 名が current として返る反例を観測した。`git ls-files -v` の flag guard を追加した後は、両 flag で CLI query と index rebuild が exit 8 / `staleIndex` を返し、query は `hits` を返さなかった。

**Measured, one Git clean filter:** `components/*.json` に clean filter を設定し、同じ長さの Component 名 `BaseButton` を working tree で `XaseButton` に変更した。filter が index content を `BaseButton` へ正規化するため、Git status は空、clean OID と index OID は一致した。これは現在の revision 計算が transformed representation から実 working bytes の変更を識別できない反例である。filter guard の前には CLI query が旧 `BaseButton` を current として返した。tracked Canonical path の `filter` attribute を確認して拒否する guard の後は、query と rebuild が exit 8 / `staleIndex` となり、hits を返さなかった。現行実装は filter を使う Canonical path を安全側で拒否するが、Git filter のある Repository 全般を architecture 上サポート不能と結論しない。

**Measured, one concurrent branch switch interleaving:** 一時 Repository の 2 branch で Component 名だけを `BaseButton` と `XaseButton` に変え、manifest revision は同じにした。baseline branch から Index を構築し、CLI query の最初の `git status` 完了直後に barrier を置いて alternate branch へ switch した。guard 前は old `BaseButton` hit を exit 0 で返した。これは同時 Git 操作中に stale result を返す実際の反例である。calculator の末尾で同じ Canonical pathspec の Git status を再実行し、最初の status output と一致しないとき `staleIndex` とする guard を追加した。同じ barrier 条件では exit 8 / `staleIndex` / hits なしへ変わった。barrier instrumentation は probe 後に production source から除去した。**Unknown:** status 2 回の間以外の interleaving、hidden flags / attributes の同時変更、最終 check 後の外部 write、ABA、一般的な snapshot guarantee。非協調同一 worktree writer の完全な安全性は証明していない。

**Measured latency:** Starter Sample の CLI query p95 は Git flag guard 前 103.752 ms（8 回）、flag guard 後 219.236 ms（40 回）、filter guard 後に Repository 内 index を使った run で 303.429 ms（40 回、最大 327.603 ms）だった。Index を Application Support へ移した後の別 run は 353.228 ms（40 回、最大 407.280 ms）だった。追加 status guard 後の別 run は 404.611 ms（40 回）。いずれも nearest-rank p95 で、現在の 250 ms 比較基準を超えた。実行時点と index 配置が異なるため両 run の差を配置の効果と断定できない。この測定は普遍的な性能保証でも大規模 shard の推定でもない。**Not measured:** branch switch の他の interleaving、concurrent pull / external edit、symlink、watcher、他の Git filter / attributes。

## Conclusion

Git の hidden tracked flag と clean filter による逐次 stale result の反例はガードで拒否できた。branch switch を最初と最後の status の間へ入れた 1 条件も guard で拒否できた。これは任意の同時 Git 操作への保証ではない。追加 check の性能 cost と、より低 cost な safe revision 計算は [Low-cost freshness Spike](../low-cost-freshness/SPIKE.md) で扱う。revision 計算と復旧 protocol は最終化しない。

## Artifacts

- [probe.py](artifacts/probe.py): hidden Git index flags と CLI query latency の逐次 probe。
- [result.json](artifacts/result.json): flag ごとの status / query outcome と raw latency。
- [git_filter_probe.py](artifacts/git_filter_probe.py): Git clean filter が working bytes を status から隠す再現 probe。
- [git-filter-result.json](artifacts/git-filter-result.json): guard 前後の filter scenario の観測結果。
- [branch-switch-race-probe.py](artifacts/branch-switch-race-probe.py): 最初の status 後に checkout を挿入する再現 probe。
- [barrier-instrumentation.patch](artifacts/barrier-instrumentation.patch): probe 専用の一時 barrier。production code には含めない。
- [branch-switch-race-before-guard.json](artifacts/branch-switch-race-before-guard.json)、[branch-switch-race-result.json](artifacts/branch-switch-race-result.json): guard 前後の raw outcome。
- [regression_replay.py](artifacts/regression_replay.py)、[regression-replay-result.json](artifacts/regression-replay-result.json): production CLI の filter / hidden-flag fail-closed regression replay。
- [IndexProjectionSpikeTests.swift](../../../../Tests/HamiiTests/IndexProjectionSpikeTests.swift): query row read 後の実 branch switch test。

Pull / external edit と query/reindex が交錯する barrier probe と raw event trace は未作成。
