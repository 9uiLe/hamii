# Automatic Index Recovery の Eligibility

## Related Decision

[Local Index の復旧方式](../../ADR.md)。Automatic full rebuild の publication protocol は [Automatic Full Rebuild Spike](../automatic-full-rebuild/SPIKE.md) で検証した。この Spike は **どの失敗を自動復旧へ渡してよいか** だけを調べる。

## Hypothesis

Coordinated Canonical state が Ready、Stable、Snapshot と generation の一致、Git oracle の検証を満たすとき、公開済み SQLite を変更せずに Derived Index だけの failure を分類できる。`ExplicitlyUnbound` current Index は slow-only Query を継続し、Canonical / coordination / source / storage の問題は自動復旧へ渡さない。

## Questions

- Missing、obsolete schema、malformed metadata、corrupt SQLite、stale Bound Index を derived-only として区別できるか。
- Read-only classification は公開済み DB bytes を変えないか。
- Canonical pending / unknown、Git hidden flag、raw edit、unbound source change、storage path error を自動復旧から除外できるか。
- Candidate creation / SQLite write / publication の失敗で旧 published Index と fail-closed Query を保てるか。
- Scope、availability、component usage を含む Snapshot で candidate と manual full rebuild の Query rows が一致するか。

## Prototype Scope

`AutomaticFullRebuildSpikeTests` に test-only `RecoveryEligibility` と read-only SQLite probe を追加する。Published DB は `SQLITE_OPEN_READONLY` で schema と metadata を読む。Canonical 側は `WorktreeCoordinator`、`CanonicalRepository`、`CanonicalGenerationStore`、`GitCanonicalRevisionCalculator` の既存境界を使う。Candidate generation は既存の optimized two-phase Spike helper を使う。Production Query の stale rejection と `LocalIndex` constructor の挙動は変更しない。

## Out of Scope

Production classifier / auto recovery API、任意の非協調 writer の安全保証、full rebuild transaction protocol の再選択、incremental indexing、実ディスク容量不足・権限変更、power-cut durability、Query 毎の SQLite integrity scan。

## Measurements

分類ごとの verdict、公開済み DB の分類前後 bytes、failure injection 後の descriptor / bytes / Query、mixed fixture の scope ごとの Query rows を記録する。性能値はこの Spike の判断基準ではない。

## Success Criteria

- Canonical が Ready / Stable / coherent / Git verifiable の場合だけ derived-only failure が `autoRecoverable` になる。
- `ExplicitlyUnbound` current は `alreadyCurrent`、source change 後は `manualOnly`。External state を自動的に coordinated generation へ採用しない。
- Obsolete / malformed / corrupt DB の read-only classification は公開 bytes を変更しない。Storage path failure は corrupt Index と誤分類しない。
- 3地点の test-only failure injection で旧 published bytes / ID、Canonical state、Query rejection が維持される。
- Mixed semantic fixture の candidate descriptor source と全 scope の Query rows が manual full rebuild と一致する。

## Failure Criteria

Canonical Unknown / pending を自動対象に含めること、storage failure を corrupt DB とすること、read-only probe が既存 DB を再生成すること、失敗 candidate の rows を Query へ出すこと、`ExplicitlyUnbound` current への不要な rebuild。

## Result

**Confirmed in test-only prototype:** `testRecoveryEligibilitySeparatesDerivedFailuresFromUnboundAndCanonicalProblems` は missing、obsolete schema、malformed metadata、corrupt SQLite を `autoRecoverable`、valid Bound current と `ExplicitlyUnbound` current を `alreadyCurrent`、unbound source change を `manualOnly` と分類した。Raw edit、pending merge gate、Git assume-unchanged、missing / pending Canonical generation、Canonical journal pending、および Index path が directory である storage-path failure は `blocked` だった。Obsolete / malformed / corrupt DB の分類前後 bytes は一致した。既存 `LocalIndex.init` は旧 schema を再生成するため、production classifier はこの constructor より先に read-only probe を実行する必要がある。

`testRecoveryFailureInjectionLeavesPublishedBytesAndQueryFailClosed` は candidate creation 前、candidate SQLite transaction 中、publication 前で test-only error を注入した。各地点で旧 published bytes と `IndexGenerationID` は変わらず、Query は stale を拒否した。SQLite transaction failure の candidate root は cleanup された。これらは注入した error であり、実 disk-full / permission fault の動作測定ではない。

`testMixedSemanticFixtureMatchesManualFullProjection` は App / Commerce / Checkout / Account scope、Scope ownership、deny availability、2 component usages を含む Snapshot を使用した。Candidate descriptor の source identity / binding / document revision と4 scope の Query rows は manual full rebuild と一致した。

**Limitations:** 分類器と failure orchestration は test-only。Read-only probe は schema、`PRAGMA integrity_check`、必須 metadata を確認するが、全 projection rows の semantic checksum は行わない。`LocalIndex.init` が current schema でも schema marker を再書込するため、失敗注入時の bytes 比較は各 recovery attempt の直前・直後に行った。Raw external writer の完全な concurrent snapshot 保証と power loss はこの Spike の結論に含まれない。

## Conclusion

検証した derived-only / Canonical / storage failure の区別は成立した。Automatic full rebuild は **coordinated で検証可能な Canonical state と、明確に分類した Derived Index failure** に限るという Decision を支持する。検証後の ADR Decision はこの範囲を採用し、Status は `Implementation Required` となった。Production classifier / recovery は未実装である。Incremental reindex の採否は別の最適化 Decision として扱う。

## Artifacts

`Tests/HamiiTests/AutomaticFullRebuildSpikeTests.swift` の focused tests。Generated DB と一時 fixture は commit しない。
