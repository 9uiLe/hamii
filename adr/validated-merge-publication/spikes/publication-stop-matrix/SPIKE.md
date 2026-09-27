# Publication stop matrix

## Related Decision

[Validated merge candidate publication](../../ADR.md)

## Hypothesis

`WorktreeCoordinator` の pending gate、検証済み candidate identity、source に結合した Index generation を用いれば、publish 中の停止後にも未知 state を利用可能にせず復旧できる可能性がある。方式は未決定。

## Questions

- Git ref / worktree / Index の各更新地点で SIGKILL された場合、何が durable に残るか。
- Source worktree の readers、CLI query、GUI client は pending と publication の各地点で何を観測するか。
- Candidate と source の CanonicalSnapshot identity、Index source generation をどう結合できるか。
- Semantic validation 失敗、Index build 失敗、cleanup 失敗で両 branch と旧 Project はどう残るか。

## Prototype Scope

Disposable Git repository に valid / semantic-invalid merge candidate を作り、候補 protocol を production `WorktreeCoordinator`、CanonicalRepository、LocalIndex に近い境界で実行する。別 OS process の writer / reader を使い、pending、Git 更新、Canonical 検証、Index build、Index publish、gate release の各地点で停止する。再起動後の recovery と Query を記録する。

## Out of Scope

Raw external writer の lossless 保証、Power-loss durability の最終判断、UI conflict resolution、production merge publish feature の実装。

## Measurements

各停止地点の HEAD / branch / Canonical bytes identity / pending record / Index source generation / published generation ID / query result / client token / recovery path。Valid publish latency、candidate build time、Index rebuild time、recovery time を p50 / p95 で分けて測る。

## Success Criteria

未知または不一致の Canonical / Index state は fail closed。中間状態を Query と mutation に公開しない。復旧後の Query は検証済みの同一 Snapshot に由来する Index だけを使う。Semantic-invalid candidate は公開されず、両 branch の有効状態を保つ。

## Failure Criteria

Future / mixed Index の検索結果、旧 client token の再受理、未検証 Canonical state の公開、候補失敗時の有効 branch history の損失、または pending gate の早期解除。

## Result

未実施。`git merge check` は candidate validation と一時 Index rebuild のみ検証済みで、publication の Evidence ではない。

## Conclusion

方式は未決定。Result 取得後に ADR の Decision Criteria と照合する。

## Artifacts

実測時にこの Spike の `artifacts/` に停止地点と生データを保存する。現時点で artifact はない。
