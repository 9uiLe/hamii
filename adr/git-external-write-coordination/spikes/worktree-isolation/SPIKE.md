# Worktree writer domain の分離

## Related Decision

[External Git Write ADR](../../ADR.md) の「1 worktree = 1 coordinated writer domain」という仮説。

## Hypothesis

**Inferred, unverified:** 独立 writer を別 branch / worktree に置けば、各 writer は他方の Canonical working bytes を直接置換せずに作業できる。ただし同じ worktree に外部 writer が入る場合と merge 時の conflict は別に扱う必要がある。

## Questions

- 複数 hamii process が同じ worktree を扱う場合、`.hamii/write.lock` と revision guard はどこまで協調するか。
- 別 worktree の Git operation、shared Git metadata、cleanup が他方の作業を妨げるか。
- editor / CLI / CI の作業単位を worktree にどう結び付けるか。
- 非協調 writer が同じ worktree に入ったことをどう検出・表現するか。

## Prototype Scope

一時 Git repository に 2 つ以上の worktree を作り、各 worktree で hamii CLI mutation と Git operation を barrier 付きで実行する。worktree path、branch、HEAD、Canonical bytes、lock path、journal の独立性を確認する。同一 worktree の非協調 write は対照条件として別に測る。

## Out of Scope

同時編集を同一 working tree 上で lossless にする保証、production worktree manager の実装、merge algorithm の採用。

## Measurements

各順序での両 worktree の bytes、revision、Git status、lock / journal path、CLI outcome、失われた編集数。環境、command、barrier、試行回数を記録する。

## Success Criteria

正式経路として想定した別 worktree 間で一方の未統合 Canonical bytes を他方が直接上書きする試行 0 件。各 worktree の crash recovery が他方の journal に触れない。

## Failure Criteria

別 worktree の保存が他方の working bytes を消す、lock / journal が誤って共有される、または必要な Git 操作が他方の継続作業を破壊する。

## Result

**Measured, narrow case:** macOS 26.2 / Git 2.52.0 の一時 Repository で baseline commit から 2 worktree を作り、双方で revision 0 から別々の Page を 1 件ずつ CLI mutation した。各 worktree は自分の Page のみを持ち、他方の未統合 Page shard は存在しなかった。lock と journal の path も worktree ごとに分かれた。**Unknown:** 並行書込・checkout/pull・crash recovery・同一 worktree の外部 writer。1 回ずつの逐次 mutation を一般保証に拡張しない。

**Measured, concurrent CLI pair:** 同じ macOS 26.2 / Git 2.52.0 の一時 Repository に 2 worktree を作り、各 revision で異なる Page を作る CLI mutation を同時開始した。20 組すべてで両 subprocess の実行区間が重なり、両 worktree は revision 20 に到達した。各 worktree は自分の 20 Page のみを持ち、他方の未統合 Page はなかった。**Not measured:** 同時 Git checkout/pull、shared Git metadata の書込競合、process crash、merge、同一 worktree の external writer。

## Conclusion

別 worktree での逐次編集と 20 組の重なった CLI 保存は成立した。Product Contract は [External Git Write ADR](../../ADR.md) に決定した。**Unknown:** production の managed Git operation、merge publication、crash / power-loss 境界を含む実装保証。この測定を全 worktree operation の証明とは扱わない。

## Artifacts

- [probe.py](artifacts/probe.py): 一時 Repository での 2 worktree / 2 CLI mutation probe。
- [result.json](artifacts/result.json): 対象環境と観測結果。
- [concurrent_probe.py](artifacts/concurrent_probe.py): 別 worktree で重なった CLI mutation の probe。
- [concurrent-result.json](artifacts/concurrent-result.json): 20 組の実行区間 overlap と最終 Document の観測結果。
