# Spike: Capability の契約粒度

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 01 IR / 03 UIKit Runtime
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

property と target runtime に結びつく semantic capability は無言の loss を防げる。

## Method

Stack/Button/Navigation/Toolbar/Remote Asset を SwiftUI/UIKit の複数 OS profile へ lowering し、node 単位・property 単位・contract 単位の registry を比較する。

## Evidence to collect

false-positive/false-negative、diagnostic の理解可能性、registry entry 数と更新工数を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

Unsupported と Approximate を明確に区別し、Canvas/Host/Generator/AI の結果が一致する。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
