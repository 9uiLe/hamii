# Spike: Local Query Index の鮮度判定

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 09 Local Query DB
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

fingerprint と revision により index drift を検出し、必要な entity だけ再 index できる。

## Method

1k/10k/50k Layer で Git pull、branch switch、外部 edit、未commit patch、DB 破損を再現する。

## Evidence to collect

query p50/p95、incremental/full rebuild 時間、drift 検出率、誤った query revision 数を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

破損時に正本から再構築でき、stale result を current と報告しない。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
