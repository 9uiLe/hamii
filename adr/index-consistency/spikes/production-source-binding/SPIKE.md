# Production Index source binding

## Related Decision

[Local Query Index の自動復旧と世代公開](../../ADR.md)。この Spike は安全な fast path の方式を決めず、公開済み Index がどの CanonicalSnapshot から生成されたかを production path で検証する。

## Hypothesis

Coordinated CanonicalSnapshot を Index build の単一入力にし、rows と `IndexGenerationID` / `sourceCanonicalIdentity` を同じ SQLite transaction に保存すれば、Query と merge publication が source mismatch を fail closed にできる。

## Questions

- Document と source identity を異なる observation から渡せる現在の API をどう閉じるか。
- Build、SQLite commit、DB file publication の各停止点で完全な generation だけを current として扱えるか。
- 通常 Query と merge gate release が同じ source binding を検証できるか。

## Prototype Scope

現行 production API と SQLite metadata の baseline を確認し、coordinated snapshot、generation metadata、一般 Query、merge publication の回帰試験を追加する。

## Out of Scope

Shared Worktree Generation の採用、Safe Fast Path、incremental reindex、非協調 writer の atomic snapshot 保証、power-loss durability。

## Measurements

正しさの判定点は rebuild ごとの generation ID、同じ source の再 build、欠損・破損 metadata、source mismatch、SQLite rollback、file publication、merge recovery とする。性能値はこの Spike の採用条件ではない。

## Success Criteria

IndexProjection の Document と保存する source identity が同じ coordinated observation に由来する。一般 Query と merge gate が欠損・破損・mismatch を拒否し、既存 Git freshness guard も通る。Index failure で Canonical を rollback しない。

## Failure Criteria

異なる observation の Document / identity を組み合わせられる、未完了 generation を current とする、source mismatch を持つ Index の検索結果を返す、または merge gate を解除する。

## Result

2026-09-27 のコード確認では、`LocalIndex` schema 5 の metadata は `documentID`、`revision`、`canonicalRevision` のみ。`LocalIndex.rebuild(from: Document, canonicalRevision:)` は source snapshot identity を受け取らない。`PublishedMergeIndex` は別 SQLite file を build して rename するが、`ValidatedMergePublisher` は publication 後に `CanonicalRepository.snapshotDuringManagedGitTransition()` の identity と published Index metadata の同一性を照合できない。`CanonicalRepository` は coordinated lock 内で Document と canonical JSON bytes identity を同時に取得する API を持つ。これは production binding の未実装箇所を示すコード確認であり、性能測定や安全性の完成証明ではない。

Production schema 6 では `CanonicalRepository.withCoordinatedSnapshot` が Document と Canonical JSON path/bytes identity を一つの lock 境界から返す。`LocalIndex.rebuild` はその Snapshot だけを projection source とし、rows、`sourceCanonicalIdentity`、新規 `indexGenerationID`、従来の CanonicalRevision を一つの SQLite transaction に記録する。同じ Snapshot の二度の rebuild で source identity は等しく、generation ID は異なった。metadata の欠損、形式破損、source mismatch、Canonical bytes 変更は Query を `staleIndex` で拒否した。metadata INSERT 失敗時には SQLite rollback により旧 rows と旧 generation が共に残った。旧 schema 5 は disposable Index として再生成し、metadata がない状態の Query は拒否した。

Merge publication は candidate Snapshot の source identity と公開後の descriptor を照合する。公開直後に source metadata を故意に改変した試験では pending gate が残り、Canonical ref は candidate のまま、recovery が candidate Snapshot から full rebuild した後だけ gate が解除された。正常 publication 後の再 recovery では source identity と generation ID が変化しなかった。既存の Git freshness guard と 19 stop-point process-crash 回帰試験は維持する。非協調 writer、停電、一般の Index 世代切替、end-to-end 性能はこの結果に含まれない。

## Conclusion

検証した production full rebuild / merge publication 経路では、rows と source metadata を結合し、source mismatch を fail closed にできた。Safe Fast Path、一般の atomic generation publication、incremental recovery は未決定である。Index consistency ADR は `Spike Required` のまま維持する。

## Artifacts

Baseline: `Sources/HamiiFormat/CanonicalRepository.swift`、`Sources/HamiiIndex/LocalIndex.swift`、`Sources/HamiiIndex/PublishedMergeIndex.swift`、`Sources/HamiiFormat/ValidatedMergePublisher.swift`（commit `b881604fad65c0c8cf3720e9b2a3f2191c4c57d5`）。Regression: `Tests/HamiiTests/IndexGenerationBindingTests.swift`、`Tests/HamiiTests/ValidatedMergePublicationTests.swift`。生成 artifact はない。
