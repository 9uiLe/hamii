# Spike: Asset の Git/LFS 閾値と remote policy

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 12 Asset Storage
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

logical ID と content hash、Git/LFS/remote/cache 分離で asset integrity と運用可能な clone size を両立できる。

## Method

小/大 binary、重複 asset、LFS object 欠落、remote offline、cache eviction、secret URL を含む fixture を用意する。

## Evidence to collect

repo/clone bytes、asset 解決 p95、hash mismatch、offline behavior、LFS absent 状態を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

cache 削除後も document が正しく開き、欠落 LFS は preflight で判明し、secret URL は保存拒否される。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
