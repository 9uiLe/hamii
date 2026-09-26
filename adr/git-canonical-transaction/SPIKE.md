# Spike: Git Canonical Format の分割粒度と保存 transaction

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 08 Git Repository Storage
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

分割 JSON と staging/recovery で Git friendly な正本を torn state なく保存できる。

## Method

entity/page shard 案を 1k/50k Layer fixture で比較。保存各段階で process kill、二人の branch merge、外部 edit と pull を再現する。

## Evidence to collect

changed file 数、diff 行数、open/save p50/p95、conflict 件数、recovery revision と reference validation を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

crash 後に complete old/new revision に復旧し、無関係 entity に diff が出ず、merge 後に全参照が検証される。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
