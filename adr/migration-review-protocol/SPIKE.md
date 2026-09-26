# Spike: Migration の review と ambiguous value 解決

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 10 Migration / 11 Destructive Migration
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

isolated worktree と manual resolution により曖昧・破壊的変換を安全に review できる。

## Method

v1→v2→v3、dirty tree、literal color→複数 token、missing asset/LFS、unsupported component、途中 kill を試す。

## Evidence to collect

元 tree hash、migration report、manual decision、edge repeatability、validation、fresh index rebuild、review diff を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

元 tree が review 前に変わらず、曖昧値の自動選択がなく、全 edge を再実行して同じ結果になる。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
