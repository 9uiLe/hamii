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

未実施。既存 production path は維持する。

## Conclusion

未判断。Evidence 完了後も ADR は Decision まで `Spike Required` を維持する。

## Artifacts

必要な小さい summary のみ Spike 配下に置く。大きい生成物・build output は commit しない。
