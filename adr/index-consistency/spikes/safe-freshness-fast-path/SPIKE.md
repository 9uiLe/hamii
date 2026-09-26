# 安全な Canonical freshness fast path

## Related Decision

[Index consistency ADR](../../ADR.md) の Query 時 freshness 判定。入力となる snapshot 保証は [CanonicalSnapshot Spike](../consistent-canonical-snapshot/SPIKE.md) で扱う。

## Hypothesis

**Tentative:** `definitely current` を返せる条件を限定できれば、Query ごとの高 cost な Git / bytes 検査を避けられる。不確実なら slow verification へ落とし、slow path も検証不能なら `staleIndex` を返す。`probably current` は positive 判定に使わない。

## Questions

- 同一 worktree で GUI / CLI / AI が `.hamii/write.lock` と共有できる cross-process epoch / lease は何か。外部 writer と Git operation をどう検出して lease を無効化するか。
- Watcher の event loss / overflow / sleep / process restart / branch switch 後に、どの slow verification で再同期するか。
- Git HEAD・manifest revision・mtime・size・directory metadata のどの組合せが false negative を持つか。
- `CanonicalSnapshot` と `sourceCanonicalRevision` がどの条件で current と証明できるか。IndexGeneration の一致とは別に何を調べるか。
- definitely-current / unknown / stale の率、query p50/p95、slow path cost、false-positive invalidation はどれだけか。

## Prototype Scope

候補 fast check を dirty / staged / untracked / filtered / hidden-flag / unrelated commit / branch switch / restored metadata / restart で同一 oracle に照らす。必ず `certainly current | unknown | stale` を区別し、unknown は slow verification または fail-closed とする。Coordinator 内の writer と external writer の保証範囲を分ける。

## Out of Scope

安全条件の証明前に cached result を返す production implementation、watcher を唯一の正本とすること、External Git Write ADR の writer ownership 決定。

## Measurements

Fast check の p50/p95 と positive/unknown/stale 件数、slow verification の p50/p95、Query 全体の p50/p95、見逃し件数、不要な失効件数、restart/overflow 回復時間。小・中・大規模の file count と bytes を併記する。

## Success Criteria

`certainly current` の全 tested cases で false negative 0。対応範囲を機械的に表現でき、範囲外は必ず unknown / stale。Slow path が CanonicalSnapshot の一貫性保証と整合し、再同期後の IndexGeneration を誤認しない。

## Failure Criteria

外部 bytes が変わったのに `current` と返す、watcher event が来ないことを変更なしの証拠にする、または Git transformed representation の一致を working Canonical contents の一致とみなす。

## Result

**Confirmed negative control:** [manifest_fast_path_probe.py](artifacts/manifest_fast_path_probe.py) は Starter の Page 名 `Design` → `Resign` を同じ bytes 長で外部編集し、mtime を復元した。Canonical の意味は変わるが `hamii.json` bytes と対象 file の size/mtime は変わらない。manifest + file metadata を fast-path positive に使うと stale を current と誤認する。100回の manifest file read は p95 **0.01675 ms** だったが、安全性 gate を満たさないので採用できない。

**Confirmed from existing Spikes:** [Low-cost freshness](../low-cost-freshness/SPIKE.md) は size/mtime の false negative と double byte scan の concurrent snapshot false negative、[Concurrent Git mutation](../concurrent-git-mutation/SPIKE.md) は Git clean filter と hidden flags が status に隠す変更を記録した。現在の guarded Git calculator は該当状態を拒否するが、Canonical files 無変更の commit でも HEAD OID により false-positive invalidation する。Starter copy の fresh CLI query p95 は 418.61 ms（40-run）、stale detection は 424.17 ms（20-run）。250 ms は比較基準であり SLA ではない。

**Unknown / not implemented:** external writer が存在する可能性のある一般 worktree で positive を返せる trusted fast condition、cross-process epoch、watcher gap/overflow recovery、safe slow verifier、fast/slow hit rate、end-to-end latency。Coordinated-writer-only epoch は候補であって製品保証の決定ではない。

## Conclusion

低 cost という理由だけでは fast-path positive を許可できない。今回の manifest/metadata shortcut は **Failure Evidence**。安全に `current` と証明できる条件が未確定の間は現行 slow verification / `staleIndex` を維持し、方式を選定しない。

## Artifacts

- [manifest_fast_path_probe.py](artifacts/manifest_fast_path_probe.py)、[manifest-fast-path-result.json](artifacts/manifest-fast-path-result.json): 実 Canonical Page 名と metadata を使う negative control、raw latency。
