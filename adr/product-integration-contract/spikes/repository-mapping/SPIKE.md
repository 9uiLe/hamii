# Spike: Product Integration Contract の実証

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make を検証する。全体の優先順位は [Technical Spikes](../../../../docs/spikes.md) を参照。

## Hypothesis

semantic contract と repo profile を渡せば AI は異なる product architecture に UI intent を保持して統合できる。

## Questions

二つ以上の repo で inputs/events/bindings/tokens/a11y を追跡できるか。AI は不明な mapping を保留できるか。

## Prototype Scope

同じ ProfileHeader を異なる repository convention の二つ以上の実 repo に移植し、unknown mapping を意図的に含める。

## Out of Scope

hamii IR に MVVM/TCA/DI を追加すること、AI が生成した差分の自動 merge、任意 repository の完全対応。

試作 code をそのまま production code に昇格させない。

## Measurements

build/test、inputs/events/bindings/tokens/a11y 対応表、誤 mapping、Human 修正量、diff review 時間を記録する。

実行環境、fixture、command、実装 commit、raw data を記録する。必要なときだけ `artifacts/` を作成し、巨大な build output は commit しない。定量 budget は実験前に固定する。

## Success Criteria

両 repo で contract の各項目が追跡可能で、unknown mapping を silent guess しない。

## Failure Criteria

contract の意味が失われる、unknown mapping を silent guess する、または差分が review 困難。

## Result

未実施。実測値、観察、失敗、成果物への link を記入する。

## Conclusion

未実施。結果が ADR の Options と Current Hypothesis をどう変えたかを記入し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
