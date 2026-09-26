# Spike: Product Integration Contract の実証

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 14 Product Integration
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

semantic contract と repo profile を渡せば AI は異なる product architecture に UI intent を保持して統合できる。

## Method

同じ ProfileHeader を異なる repository convention の二つ以上の実 repo に移植し、unknown mapping を意図的に含める。

## Evidence to collect

build/test、inputs/events/bindings/tokens/a11y 対応表、誤 mapping、Human 修正量、diff review 時間を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

両 repo で contract の各項目が追跡可能で、unknown mapping を silent guess しない。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
