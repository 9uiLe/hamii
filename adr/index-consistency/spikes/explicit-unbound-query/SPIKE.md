# Explicitly Unbound Index の Slow Query

## Related Decision

[Published Index の鮮度証明](../../ADR.md)。既存の明示的な `hamii index rebuild` が、coordinated CanonicalGeneration に結び付けられない Snapshot から作った Index を、どの Query path で利用できるかを明確にする。

## Hypothesis

**検証前の仮説:** `sourceCanonicalGeneration` が意図的に空の Index は fast witness を発行できない。一方、coordinated Snapshot identity と現行 Git oracle が毎回 current を確認できれば、その呼び出しだけ slow Query rows を返せる。Key 欠損・破損を意図的な unbound と混同してはいけない。

## Questions

- 既存の CLI contract は外部編集後の `staleIndex → 明示的 rebuild → slow Query` を許可しているか。
- 現行 schema 7 は意図的な unbound と key 欠損・破損を表現上区別できるか。
- Fast witness 発行条件を強めたとき、この既存 slow path を誤って失わないか。

## Prototype Scope

Baseline は `067934e` の production CLI / `scripts/smoke-cli.py`。Production `IndexQuerySession` の未コミット実装候補で、slow path に Bound generation を必須とした場合の CLI smoke を実行し、実際の失敗を確認した。Evidence commit はこの Spike 文書のみを含み、未コミット実装候補を production code として保存しない。

## Out of Scope

外部 writer を coordinated writer domain へ採用する operation、自動 Index recovery、同時 raw writer の atomic snapshot 保証、Fast path の性能測定。

## Measurements

2026-09-27、arm64 macOS、Swift 6.4。P5 baseline の `scripts/check.sh` に含まれる CLI smoke は成功。Bound を slow Query の必須条件とした未コミット実装候補では `python3 scripts/smoke-cli.py` が exit 1、期待していた外部編集後の再構築済み Index Query は CLI exit 8 / `staleIndex` となった。これは correctness / contract regression であり latency benchmark ではない。

## Success Criteria

外部編集直後の旧 Index は Query を拒否する。明示的 rebuild 後、exact Snapshot identity と Git oracle が current なら slow Query を許可するが Fast witness は発行しない。欠損・破損した binding metadata は rows を返さない。

## Failure Criteria

意図的な unbound Index を `KnownCurrent` Fast witness に昇格する、または metadata 欠損・破損を意図的 unbound と同じ扱いで Query を許可する。既存の明示的 rebuild 後 slow Query が理由なく使えなくなる。

## Result

**Confirmed:** `scripts/smoke-cli.py` は Component shard の外部編集後に旧 Index の `staleIndex` を確認し、明示的 `index rebuild` 後の新 Component 名 Query 成功を要求する。現行 schema 7 の rebuild は Stable generation の Snapshot identity が違う場合、`sourceCanonicalGeneration = nil` を選び、SQLite metadata には空文字列を保存する。既存 `LocalIndex.components` はその場合も source identity / Git revision を Query ごとに照合する。

**Confirmed regression in uncommitted candidate:** Slow path に `sourceCanonicalGeneration == Stable generation` を一律に要求すると、明示的 rebuild 後の Query が `staleIndex` となり CLI smoke が失敗した。

**Unresolved implementation detail:** schema 7 の空文字列だけでは intentional unbound と accidental empty を明確に区別できない。Disposable Index schema の次版では `Bound(G)` / `ExplicitlyUnbound` を必須 marker とし、missing / malformed / unknown marker を Invalid として拒否する必要がある。

この Result は Evidence commit `b402e35` 時点の schema 7 を記述している。後続の production 実装では schema 8 の必須 binding marker として区別する。

## Conclusion

Slow verification は `BoundCurrent`（rows + process-local witness）と `UnboundCurrent`（rows only、次回も slow）を別の成功結果として扱う。ExplicitlyUnbound は Fast path の positive proof を弱めずに、明示的 rebuild の既存 contract を維持できる。Index freshness ADR は `Implementation Required` のまま、Decision を狭く明確化する。

## Artifacts

- [CLI smoke](../../../../scripts/smoke-cli.py): 外部編集後の stale / 明示的 rebuild / slow Query の検証ケース。
- P5 baseline `067934e` の Verify `36325567176`: success。未コミット候補の `python3 scripts/smoke-cli.py`: exit 1 / `staleIndex`。
