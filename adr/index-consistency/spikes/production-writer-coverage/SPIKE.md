# Production Canonical writer coverage

## Related Decision

[Index consistency](../../ADR.md)。Production の共有 CanonicalGeneration を導入する前に、協調 writer が参加すべき経路と、世代を進めない経路をコード上で確定する。

## Hypothesis

**Tentative:** `WorktreeCoordinator` の同じ worktree lock 下で Canonical state を変更する全 production 経路を列挙できる。世代 protocol はそれらの経路にだけ組み込み、Query や Index rebuild は世代を進めない。

## Questions

- Canonical JSON を書く production 入口は何か。
- Git による Canonical state の入れ替えはどの入口を通るか。
- Asset blob、Agent profile、Index build は Canonical generation とどう関係するか。
- semantic no-op と失敗した mutation で世代を進める必要があるか。

## Prototype Scope

`Sources/` の writer call graph と既存の lock / pending gate を静的に監査する。実装変更はこの Spike に含めない。

## Out of Scope

Shared generation の永続 schema、crash ordering、production Query fast path、非協調 writer の安全保証、Index incremental recovery。

## Measurements

入口、変更される Canonical state、既存の coordination、世代遷移の必要性を表で照合する。静的監査であり、性能値は測定しない。

## Success Criteria

既知の正式 writer が漏れなく分類され、世代を進めない操作と直接編集が区別される。実装時の停止・再起動テスト対象を特定できる。

## Failure Criteria

同じ worktree の Canonical JSON を正式に変更する入口を列挙できない、または各入口が共通 lock / pending protocol に参加できない。

## Result

**Confirmed by source audit, 2026-09-27:**

| 入口 | Canonical state の変更 | 現在の coordination | Generation 実装で確認する条件 |
| --- | --- | --- | --- |
| `CanonicalRepository.create` | default Agent profile と初回分割 JSON | `withExclusive`、Canonical transaction | Project 不在から最初の full Snapshot を確立し Stable 初期世代を保存する。既存 Project の record 欠損を初期化扱いしない。 |
| `ProjectService.mutate` → `CanonicalRepository.commit` | semantic mutation の分割 JSON | `withExclusive`、client precondition、journal | Canonical shard に触る前に Pending、commit / recovery 後の Snapshot から Stable。 |
| `CanonicalRepository.save` | 分割 JSON を直接保存する API | `withExclusive`、revision check、journal | `commit` と同じ世代 protocol。実運用の別入口として漏らさない。 |
| `ManagedGit.switchBranch` / `recover` | branch switch による Canonical state 入れ替え | `withExclusive`、managed transition pending | pending / rollback / new branch recovery を old/new Snapshot に結合する。同じ contents へ戻る switch でも遷移を記録する。 |
| `ValidatedMergePublisher.publish` / `recover` | immutable candidate の ref CAS と materialization | `withExclusive`、merge publication pending | ref CAS 前に Pending。old OID と candidate OID の既存 recovery 分岐に世代を結合する。 |
| `ProjectService.importRepositoryAsset` | blob を置き、成功時は asset metadata を `mutate` → `commit` | metadata は通常 mutation、blob put はその前 | metadata commit 成功で世代を一度だけ進める。競合で commit が拒否された場合は世代不変、未参照 blob は別の asset lifecycle 問題。 |
| `AgentProfilesRepository.createDefault` | 初期 `hamii-agent-profiles.json` | 現在は `CanonicalRepository.create` 内 | 初期 Snapshot に含める。将来の正式 profile mutation は共有世代 protocol に参加する必要がある。 |
| `LocalIndex.rebuild`、`PublishedMergeIndex` | Repository 外の SQLite derived data | coordinated Snapshot / merge pending gate | CanonicalGeneration は進めず、IndexGenerationID と source binding だけ更新する。 |
| CLI `query` / `index rebuild` / `git merge check` | Canonical JSON を書かない | coordinated read または isolated merge candidate | generation を進めない。merge check の candidate は source worktree への publication ではない。 |
| `ProjectService` の semantic no-op | Canonical write なし | `updated == observed.document` で `commit` を省略 | generation を進めない。 |

**Boundary:** raw Git、外部 editor / script / AI による同一 worktree 直接変更は [External Git Write ADR](../../../git-external-write-coordination/ADR.md) の Product Contract 外。shared generation だけでこれらを検知できない。Agent profile の外部直接編集も同じ扱い。CanonicalRevision の現行 oracle と production `staleIndex` 拒否を維持する。

## Conclusion

現行 production の正式 Canonical writer は初回 create、通常 commit / save、managed switch / recovery、validated merge publish / recovery に集中している。Generation store は既存の `WorktreeCoordinator` lock を利用する state primitive とし、各 writer orchestration に統合する。Index rebuild、Query、merge check、semantic no-op は CanonicalGeneration を進めない。これは静的 coverage evidence であり、停止・再起動時の正しさは後続の production regression test で検証する。

## Artifacts

この Spike 固有の生成 artifact はない。監査対象は `Sources/HamiiFormat/CanonicalRepository.swift`、`ManagedGit.swift`、`ValidatedMergePublisher.swift`、`AgentProfilesRepository.swift`、`Sources/HamiiApplication/ProjectService.swift`、`Sources/HamiiIndex/LocalIndex.swift`、`Sources/HamiiCLI/main.swift`。
