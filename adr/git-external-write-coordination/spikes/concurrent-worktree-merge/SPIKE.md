# Concurrent worktree merge と semantic validation

## Related Decision

[External Git Write ADR](../../ADR.md) の独立 writer 間の validated merge protocol。

## Hypothesis

**Inferred, unverified:** branch / worktree を分けた編集は、Git merge 後に Canonical schema、stable ID、reference、scope、component dependency を検証し、conflict を解決対象として提示できる。

## Questions

- 異なる shard、同じ shard の異なる property、同じ property の競合をどこまで Git merge で扱えるか。
- Git merge が text conflict を出さず、semantic rule だけを破る場合を検出できるか。
- merge 後に fresh index rebuild と Query validation をどう実行するか。
- 両 branch が同じ document revision で別々に進んだ場合、merge 後の revision と Preview / client session をどう再同期するか。
- conflict で停止した worktree の未統合 bytes と branch をどう保持するか。

## Prototype Scope

2 branch / worktree で独立した hamii mutation を行い、非競合変更、同一 entity の別 property、同一 property、scope promotion、参照対象削除を作る。Git merge 結果を Canonical validation と fresh index rebuild に通す。失敗時の branch / worktree / conflict file の残存を検証する。

## Out of Scope

未検証の semantic merge algorithm の採用、AI による無断 conflict resolution、強制 push / destructive reset。

## Measurements

scenario ごとの Git conflict、semantic diagnostic、保持された双方の変更、index rebuild outcome、ユーザーが特定できる entity / path。command と fixture を記録する。

## Success Criteria

双方の committed edit が review まで保持され、invalid merge を current Canonical Project として公開しない。正常 merge は validation と fresh index rebuild を通る。

## Failure Criteria

一方の edit が無通知で失われる、semantic invalidity が検出されない、または conflict 解決対象が特定できない。

## Result

**Measured, narrow case:** macOS 26.2 / Git 2.52.0 の一時 Repository で、別 branch / worktree に追加した異なる Page shard を commit 後に merge した。Git merge は成功し、双方の Page が残り、Canonical validation と fresh index rebuild も成功した。両 branch が revision 3 へ進んだため、merged Document も revision 3 だった。同じ Screen の同じ Text property を別々に更新した場合、Git merge は conflict を返し、`screens/<id>.json` を unmerged path として示した。双方の branch の編集は残った。**Unknown:** text conflict のない semantic invalid merge、merge 後の client / Preview session revision protocol、merge 中の別 writer、ユーザー向け conflict UX。これらは未測定。

## Conclusion

非競合 Page 追加と同一 Text property conflict の 2 scenario は上記の挙動だった。**Unknown:** semantic-only conflict を含む validated merge protocol 全体。未測定 scenario を終えるまで方式と UX は決めない。

## Artifacts

- [probe.py](artifacts/probe.py): 一時 Repository の非競合・競合 merge probe。
- [result.json](artifacts/result.json): merge、validation、index rebuild の観測結果。
