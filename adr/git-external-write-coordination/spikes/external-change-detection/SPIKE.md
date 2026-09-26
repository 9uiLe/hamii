# 同一 worktree の external change detection

## Related Decision

[External Git Write ADR](../../ADR.md) の非協調 external writer に対する保存中断境界。

## Hypothesis

**Inferred, unverified:** Canonical source identity と各 shard の旧 bytes を保存前後に照合すれば、多くの逐次 external modification を検出して fail closed にできる。ただし check と replace の間の非協調 write はこの方法だけで保証できない。

## Questions

- external edit、checkout、pull、hook が load、mutation、journal prepare、apply、manifest switch、recovery の各段階で入ると何が起きるか。
- 検知できる場合、外部 bytes と journal を保持したまま保存を中断できるか。
- check / replace race を残したまま「検知可能な範囲」を UI / CLI でどう正確に伝えるか。
- 同じ bytes へ収束する編集、delete / rename、Git filter、symlink はどう扱うか。

## Prototype Scope

一時 Git working tree で production transaction に barrier / hook を挿入し、外部 writer の順序を制御する。外部変更の検知、保存中断、復旧、再試行をファイルごとに観測する。必要なら source fingerprint と shard content guard の候補を prototype で比較する。

## Out of Scope

同一 worktree の任意の非協調 writer への lossless 保証を前提にすること、外部 bytes を journal から復元できるとみなすこと。

## Measurements

interleaving ごとの old / hamii / external / final bytes、検知時点、CLI error category、journal 残存、再試行 outcome。最小 APFS model の既存結果と production transaction の結果を区別する。

## Success Criteria

検知した競合は保存を中断し、外部 bytes と conflict evidence を保持する。検知できない race window を定量化し、正式 safe collaboration path の保証へ誤って含めない。

## Failure Criteria

検知した競合を無視して保存する、失われた bytes を recoverable と表示する、または race window を未記載のまま保証を主張する。

## Result

**Measured, one production barrier:** macOS 26.2 / Git 2.52.0 / Swift 6.4 で、Canonical journal が ready になった時点で Git checkout を挿入し、Component shard を別 branch の bytes に切り替えた。保存は `transactionConflict(components/component_checkout.json)` で中断し、外部 bytes と journal が残った。該当する deterministic test は成功した。

**Measured, sequential load/save gap and correction:** 同じ環境で、load 後・save 前に同じ revision の Component shard を外部編集する probe を実行した。旧 `save(document, expectedRevision:)` は外部 bytes を上書きし、1 件の再現 test が通過した。`save(document, expected: loadedDocument)` に変更し、journal 開始前に Canonical file の期待 bytes と現在 bytes を照合した後、同じ順序で外部編集を注入すると `transactionConflict(components/component_probe.json)` で保存を中断し、外部 bytes と revision 1 が残った。恒久 test `testExternalEditAfterLoadStopsSaveBeforeJournalAndPreservesBytes` が通過した。この対策は逐次変更の確認済み条件に限る。

**Measured in a separate minimal APFS model:** [既存の最小模型](../external-writer-interleaving/SPIKE.md) では check と atomic replace の間の external bytes が失われた。**Unknown:** production transaction の check-to-replace race、pull、hook、同時 retry。

## Conclusion

ready barrier より後、apply より前の checkout と、load 後・save 前の逐次外部編集に対しては保存中断と bytes 保持を確認した。**Unknown:** 残る interleaving と検出不能な race の範囲。これらを明示してから fail-closed protocol を決める。

## Artifacts

- [result.json](artifacts/result.json): ready barrier の Git checkout injection と test outcome。Probe は [ArchitectureTests.swift](../../../../Tests/HamiiTests/ArchitectureTests.swift) の `testGitCheckoutBeforeCanonicalApplyStopsSaveAndPreservesExternalBytes`。
- [SequentialExternalEditProbe.swift](artifacts/SequentialExternalEditProbe.swift): 修正前の same-revision data loss 再現 test source。現在の API では実行できない historical probe として保持する。
- [sequential-result.json](artifacts/sequential-result.json): 修正前後の観測範囲。修正後の恒久 test は [ArchitectureTests.swift](../../../../Tests/HamiiTests/ArchitectureTests.swift) の `testExternalEditAfterLoadStopsSaveBeforeJournalAndPreservesBytes`。

その他の barrier probe と bytes trace は未作成。
