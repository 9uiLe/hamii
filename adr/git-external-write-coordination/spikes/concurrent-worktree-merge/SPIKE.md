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

**Measured, narrow case:** macOS 26.2 / Git 2.52.0 の一時 Repository で、別 branch / worktree に追加した異なる Page shard を commit 後に merge した。Git merge は成功し、双方の Page が残り、Canonical validation と fresh index rebuild も成功した。両 branch が revision 3 へ進んだため、merged Document も revision 3 だった。同じ Screen の同じ Text property を別々に更新した場合、Git merge は conflict を返し、`screens/<id>.json` を unmerged path として示した。双方の branch の編集は残った。**Unknown:** production merge 中の別 writer とユーザー向け conflict UX。

**Confirmed, semantic-only invalid merge:** 別 worktree で一方は未使用 ComponentDefinition shard を削除し、他方はその Component を Screen に instantiate した。それぞれの branch は単独で `validate` に成功。`git merge --no-commit --no-ff` は exit 0、unmerged path なしで成功したが、merge 後の `hamii validate` は `component.missing` を返した。`inspect` と `index rebuild` も exit 7 で拒否した。merge を commit せず abort すると両 branch の有効な状態が保持された。**Limit:** 現行 CLI は semantic-invalid working tree を拒否するが、production の自動 merge gate / publish protocol は未実装。

**Confirmed, post-merge resync input:** 両 branch が別 Page を追加して revision 3 に到達した状態で、main worktree の Index を構築した。`git merge --no-commit --no-ff` 後も manifest revision は 3 だったが Canonical path/bytes identity は変わった。旧 Index の `query components` は exit 8 / `staleIndex` を返した。validation 後に同じ Canonical bytes を入力として `index rebuild` すると検索が再開した。さらに merge 前の revision 3 を使った `page create` は成功した。これは現行の revision guard だけでは旧 client session を失効させられない反例であり、この semantic mutation による既存変更の喪失は観測していない。**Not implemented:** merge による client / Preview session の失効と generation advancement。試験は merge を commit していない使い捨て worktree の逐次手順であり、同時 writer や atomic publish は検証しない。

## Conclusion

Git text merge 成功だけでは Semantic validity を保証できない。`component.missing` は現行 validation で拒否でき、旧 Index は stale として拒否できた。正式な merge gate、generation / Index publication、client session resync、同時 Git 操作と UX は未解決であり、Product Contract はまだ決めない。

## Artifacts

- [probe.py](artifacts/probe.py): 一時 Repository の非競合・競合 merge probe。
- [result.json](artifacts/result.json): merge、validation、index rebuild の観測結果。
- [semantic_and_resync_probe.py](artifacts/semantic_and_resync_probe.py): semantic-only invalid merge と post-merge Index / client identity の使い捨て probe。
- [semantic-and-resync-result.json](artifacts/semantic-and-resync-result.json): exit status、diagnostic、revision / canonical identity、Index 再構築の観測結果。
