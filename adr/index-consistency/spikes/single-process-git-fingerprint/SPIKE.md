# Single-process Git fingerprint

## Related Decision

[Local Query Index の鮮度判定](../../ADR.md) の低 latency source identity を判断する Evidence。

## Hypothesis

`git status --porcelain=v2 --branch -z` 1 回と dirty/untracked Canonical bytes で、3 Git subprocess 方式と同じ逐次変更を検出し、nested Project の query budget を満たせる。

## Questions

unborn、tracked edit、stage、untracked、ignored、rename/delete、branch switch を区別できるか。nested Project で cold subprocess latency はどの程度か。

## Prototype Scope

一時 Git repository の Canonical file と `Samples/Starter` を用いる。status record の path と現在 bytes を digest に入れ、HEAD OID を clean tracked content の identity とする。

## Out of Scope

同時 Git 書込、symlink/filter、assume-unchanged、50k shard、production implementation。

## Measurements

scenario ごとの digest 変化と、nested Project で 8 回の Python subprocess latency。判定 budget は既存の query p95 250 ms。`status` 単体 p95 が 100 ms を超えるなら Swift 実装へ進まない。

## Success Criteria

対象 scenario の内容/path 変化を検出し、nested Project の status p95 が 100 ms 以下。

## Failure Criteria

誤った同一 digest、または status p95 が 100 ms を超える。

## Result

macOS 26.2 / Git 2.52.0 で、一時 Git repository の unborn edit、tracked edit、stage、untracked、ignored、rename/delete、commit switch の content/path 変化を全て区別した。stage 前後で working bytes が同じ場合は同じ digest だった。branch switch 後には ignored Canonical file が残り、base commit の digest とは異なったが、alternate commit からの変化は検出した。`Samples/Starter` の status-based fingerprint 8 回は 9.089、7.325、7.225、10.808、8.681、7.529、7.060、7.441 ms。p95 10.808 ms で事前の status 単体 100 ms gate を満たした。Swift 実装後の CLI query p95 は [Nested repository query latency](../nested-repository-query-latency/SPIKE.md) で 103.752 ms と測定した。

## Conclusion

single-process status は逐次変更と nested Project の subprocess cost について 250 ms query budget を満たした。concurrent write、symlink/filter、assume-unchanged、large shard の未検証点を ADR に残す。これだけで最終 protocol は決定しない。

## Artifacts

- [probe.py](artifacts/probe.py): status-based digest と scenario/latency の probe。
- [result.json](artifacts/result.json): digest と raw timing。
