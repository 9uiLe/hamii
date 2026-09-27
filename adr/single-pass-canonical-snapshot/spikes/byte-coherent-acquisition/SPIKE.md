# Byte-coherent CanonicalSnapshot acquisition

## Related Decision

[CanonicalSnapshot の bytes 取得境界](../../ADR.md)。同一 coordinated observation の Canonical JSON bytes を decode と identity に共有できるかを検証する。

## Hypothesis

既存 path discovery と lock を用い、各 Canonical JSON を一度だけ取得して保持すれば、Document / Agent profile / identity の意味を保ったまま重複 I/O を削減できる。

## Questions

- Manifest header/full decode、全 shard、Agent profile は同一 captured bytes を使えるか。
- Folder 別 ordering、filename/EntityID、Document/Asset validation、失敗分類は一致するか。
- Stable generation、symlink、sequential external edit、coordinated writer の gate は保たれるか。
- Snapshot / Phase 1 / writer wait の改善と captured byte memory cost はどれほどか。

## Prototype Scope

`#if DEBUG` の test-only Candidate を実 CanonicalRepository に追加する。既存の `canonicalJSONPaths()` と `hashIdentity` を使い、1 / 1000 / 5000 / mixed fixture で production Snapshot と比較する。各 Canonical JSON の read count と stage timing を記録する。

## Out of Scope

Production path の切替、Git oracle の変更、fd/O_NOFOLLOW、新しい Index recovery、arbitrary external concurrent writer の安全保証、Asset blob の同時 capture、power-loss durability。

## Measurements

Path discovery、bytes capture、manifest/entity/Agent decode、Document/Asset validation、identity hash、Snapshot/Phase 1、lock hold、writer wait、captured byte total の p50/p95。各 fixture 5 run を目標とし、条件を併記する。

## Success Criteria

同一 bytes・1 read/file、Document/ordered IDs/identity/diagnostics parity、主要 error categories、symlink rejection、stable gate、OS writer exclusion を確認し、Snapshot/Phase 1 の便益と memory cost を測定する。

## Failure Criteria

Decode と identity で別 bytes を使う、Document order または validation semantics が変わる、symlink・generation gate が弱まる、測定対象を production Query SLA と誤認する。

## Result

### Confirmed in the tested cases

- `#if DEBUG` Candidate は既存の `canonicalJSONPaths()` で path を取得し、各 JSON を1回だけ `Data` に捕捉する。Manifest header/full decode、shard decode、Agent profile validation、identity hash はその captured bytes を共有する。Production の通常経路は変更していない。
- 1 / 1000 / 5000 Component と mixed content で、Candidate と production の Document、folder 別の ordered IDs、CanonicalSnapshotIdentity、stable generation 判定が一致した。各成功ケースで全 Canonical JSON の read count は1だった。
- Repository Asset の blob integrity、`/var` と `/private/var` の root alias、13種類の単一故障での主要 error category が一致した。故障には Manifest 欠落 / decode、entity decode、format、filename / EntityID、Scope、Asset blob、Agent profile、symlink を含む。
- JSON に空白を1 byte 追加すると Document は同じでも両経路の identity が同じ新値に変わり、旧 stable generation は `unknownState` で拒否された。
- 別 OS process の coordinated writer は Candidate の Snapshot と Git oracle の間に source lock を取得できなかった。`assume-unchanged`、`skip-worktree`、Git clean filter の既存 Query rejection も Candidate によって迂回されなかった。

### Measured

2026-09-28、Apple M1 Pro、Xcode 27.0 / Swift 6.4、debug XCTest、ローカル一時 Git Repository。各 fixture 5回の対測定で順序を交替した。p95 は5標本の最大値。`Phase 1` は stable Snapshot と Git oracle を同じ coordinated lock 内で実行する時間であり、CLI Query end-to-end ではない。生データは [paired-measurements.json](artifacts/paired-measurements.json)。

| Fixture | JSON files / captured bytes | Legacy Snapshot p50 / p95 | Candidate Snapshot p50 / p95 | Legacy Phase 1 p50 / p95 | Candidate Phase 1 p50 / p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 Component | 4 / 1,476 B | 2.50 / 3.58 ms | 1.87 / 2.76 ms | 357.93 / 384.63 ms | 348.67 / 366.35 ms |
| 1000 Components | 1003 / 693,459 B | 164.58 / 168.98 ms | 112.53 / 114.48 ms | 512.40 / 523.47 ms | 447.62 / 451.58 ms |
| 5000 Components | 5003 / 3,477,459 B | 778.72 / 812.46 ms | 508.39 / 526.05 ms | 1147.60 / 1182.36 ms | 887.81 / 892.72 ms |
| Mixed content | 25 / 15,050 B | 7.83 / 8.14 ms | 5.89 / 6.49 ms | 349.53 / 363.75 ms | 348.27 / 374.93 ms |

5000 Component Candidate の stage p50 / p95 は path discovery 134.15 / 135.36 ms、bytes capture 154.48 / 158.51 ms、entity decode 168.69 / 178.43 ms、Document / Asset validation 35.81 / 37.24 ms、identity hash 13.92 / 14.58 ms。Captured byte total は `Data` payload の合計で、peak RSS や Swift allocator overhead ではない。Mixed fixture の Phase 1 p95 は Candidate が高く、5標本だけから安定した改善を主張しない。

Writer lock wait は別 OS process の単発試行として測った。Baseline と Candidate は同じ fixture の同じ stable Snapshot + Git oracle path で順に試した。5000 Component で Baseline の Snapshot は 742.72 ms、writer wait は 1109.41 ms、Candidate の Snapshot は 552.71 ms、writer wait は 952.00 ms。[計測値](artifacts/writer-wait.json)。待機時間は scheduler、child process 起動、oracle 実行に依存するため分布や性能保証ではない。

## Conclusion

検証した coordinated writer domain では、単一捕捉 bytes の共有は既存の受理・拒否を保ち、特に shard 数が多い fixture の Snapshot 時間を減らした。Production 採用は未判断で、ADR は `Spike Required` のまま維持する。測定した captured byte payload の保持コスト、peak memory、失敗時の詳細 error ordering、production Query end-to-end と Index recovery の統合効果を採用判断で評価する。非協調 external writer の atomic snapshot 保証は本 Spike の範囲外である。

## Artifacts

- [Paired Snapshot / Phase 1 measurements](artifacts/paired-measurements.json)。Build output、temporary Repository、test log は commit しない。
- [Writer lock wait measurement](artifacts/writer-wait.json)。
