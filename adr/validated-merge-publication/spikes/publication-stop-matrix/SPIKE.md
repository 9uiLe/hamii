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

**Measured / Confirmed for the tested interleavings:** `artifacts/probe.py` は disposable Git repository と実 SQLite Index を使い、valid candidate commit を source branch へ fast-forward する試作 protocol を 4 回実行した。各回、別 OS process の writer を `pending`、`gitUpdated`、`indexPublished`、`gateReleased` の直後に SIGKILL した。Reader は lock attempt を記録し、writer 生存中に取得できず、SIGKILL 後に取得した。最初の 3 地点では production CLI query が `transitionPending` を返した。`gateReleased` では query が current を返した。試作 recovery は source HEAD が旧または candidate commit の既知値であることを確認し、新 HEAD の場合は source / candidate の Canonical JSON identity を比較して candidate Index を source namespace に置いた後に gate を解除した。4 ケースすべてで recovery 後の query は current、旧 client token は conflict、other branch HEAD は保持された。生データは [result.json](artifacts/result.json)。

**Inferred:** lock・pending gate・validated candidate・source と一致する Index の組み合わせは、検証した phase 間停止に対する in-place publication 候補を支持する。これは production protocol の成立証明ではない。

**Unknown / not measured:** SIGKILL を Git worktree update または SQLite commit の途中に注入していない。`IndexGenerationID` と production CanonicalGeneration の結合はない。SQLite file copy は試作用で、公開済み DB reader との全 interleaving、cross-volume rename、fsync / power loss は未検証。Performance p50 / p95 と large-project scaling は測っていない。非協調 writer は保証外。

## Conclusion

In-place fast-forward と pending gate は phase 間 SIGKILL の 4 ケースで fail-closed を保った。Git 更新途中、Index generation の atomic publish、production recovery、代替方式との比較が残るため方式は未決定。ADR は `Spike Required` のまま維持する。

## Artifacts

[Probe](artifacts/probe.py)、[Result](artifacts/result.json)。数値を production performance として扱わない。
