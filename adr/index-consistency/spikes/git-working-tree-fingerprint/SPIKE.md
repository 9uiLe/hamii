# Git working tree fingerprint for index freshness

## Related Decision

[Local Query Index の鮮度判定](../../ADR.md) の changed-entity detection を判断する Evidence。

## Hypothesis

Git HEAD と working tree diff の content digest を index build 時と query 時に比較すれば、manifest revision を変えない外部 edit と branch switch を検出できる。

## Questions

tracked、staged、untracked、同一 path の再編集、branch switch、unborn repository で digest が変わるか。通常 query の latency は許容できるか。

## Prototype Scope

一時 Git repository を用い、`hamii.json`、`scopes/`、`components/`、`screens/` のみを source set として fingerprint を計算する。1k/10k/50k Layer の単一 Screen shard で cold CLI に近い process 起動込みの時間を測る。

## Out of Scope

production index code、FSEvents、Git LFS、全 Query projection、悪意ある file metadata 改竄、Git 外の canonical storage。

## Measurements

各 source state の digest 変化、誤った current 判定数、process 起動込み p50/p95。測定前 budget は 50k Layer で fingerprint p95 250 ms 以下、未検出 0 件。macOS / APFS / Git version と raw observations を残す。

## Success Criteria

対象 scenario の content 変化が全て検出され、50k Layer の p95 が budget 内。

## Failure Criteria

同じ digest で異なる canonical source を current と扱うか、latency budget を超える。

## Result

macOS 26.2 / Git 2.52.0 で 1k/10k/50k Layer を単一 Screen shard に置いた。`HEAD`、tracked diff、untracked file content を合成した digest は unborn repository の編集、tracked file の編集と同じ path の再編集、stage 済み content、untracked file 追加、commit switch を全て区別した。Stage 操作だけでは内容が変わらないため fingerprint は維持された。Python subprocess 起動込みの fingerprint p95 は 65.419 / 66.729 / 64.572 ms で、事前 budget を満たした。

この probe は clean/dirty state の順次操作だけを対象とした。fingerprint 計算中の Git checkout、同時 external edit、symlink や Git filter による working bytes と diff の相違、複数 shard の大規模 untracked project は未検証。

## Conclusion

Git-based fingerprint は通常の逐次編集に対する候補として残る。query と rebuild の間の競合時に stale data を current と表示しない protocol を検証するまで ADR の決定は保留する。

## Artifacts

- [probe.py](artifacts/probe.py): 再実行可能な Git state 試作。
- [result.json](artifacts/result.json): 5 回ずつの timing と検出結果。
