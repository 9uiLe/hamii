# Spike: Local Query Index の鮮度判定

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make を検証する。全体の優先順位は [Technical Spikes](../../../../docs/spikes.md) を参照。

## Hypothesis

fingerprint と revision により index drift を検出し、必要な entity だけ再 index できる。

## Questions

pull/外部 edit/未commit patch を検知できるか。破損 DB を正本だけから復旧できるか。query は source revision を正しく返すか。

## Prototype Scope

1k/10k/50k Layer の一時 project で full rebuild と indexed query を測り、manifest revision を変えない外部 edit と DB 破損を再現する。Git pull、branch switch、未commit patch の別経路は残る検証項目とする。

## Out of Scope

SQLite を正本にする設計、永続 SQLite migration、全 query の最適化。

試作 code をそのまま production code に昇格させない。

## Measurements

query p50/p95、incremental/full rebuild 時間、drift 検出率、誤った query revision 数を記録する。

実行環境、fixture、command、raw data を記録する。必要なときだけ `artifacts/` を作成し、巨大な build output は commit しない。今回の測定 budget は 50k Layer の full rebuild 10 秒以内、indexed query p95 250 ms 以内、外部 edit 後の誤った current query 0 件とし、実行前に固定する。プロセス起動を含む CLI latency として測る。

## Success Criteria

破損時に正本から再構築でき、stale result を current と報告しない。

## Failure Criteria

stale result を current と返す、破損 index から再構築できない、または query/rebuild が事前 budget を超える。

## Result

macOS 26.2 で 1k / 10k / 50k Layer の full rebuild は 23.387 / 130.058 / 593.740 ms、5 回ずつの indexed query p95 は 8.165 / 8.665 / 7.768 ms（CLI プロセス起動を含む）。事前 budget を満たした。破損させた SQLite file は `index rebuild` で再作成できた。

全 3 fixture で、Component 名を Canonical JSON で外部編集し manifest revision を維持すると、`inspect` は新版 `RenamedChip` を返したが index query は旧名 `Chip` を current として 1 件返し、新名は 0 件だった。誤った current query 0 件という成功基準は満たさない。これは既存実装の revision のみの鮮度判定が不足する再現例である。

## Conclusion

full rebuild と query の性能は試した fixture では十分だった。ただし性能だけで incremental detection protocol は決められない。外部編集は manifest revision を変えないため、source fingerprint または同等の changed-entity evidence が必要。Git HEAD、tracked diff、untracked bytes の fingerprint を query の fail-closed guard に追加し、tracked Component 名の外部編集後に `staleIndex`、再構築後に新版検索を CLI smoke test で確認した。Git pull / branch switch、dirty working tree、file metadata が保たれる編集を含む方式比較と計測を続ける。現時点で ADR の決定はしない。

## Artifacts

- [probe.py](artifacts/probe.py): 一時 project の fixture と測定。
- [result.json](artifacts/result.json): 各 query の観測値と集計。
