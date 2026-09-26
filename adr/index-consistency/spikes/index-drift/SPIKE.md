# Spike: Local Query Index の鮮度判定

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make を検証する。全体の優先順位は [Technical Spikes](../../../../docs/spikes.md) を参照。

## Hypothesis

fingerprint と revision により index drift を検出し、必要な entity だけ再 index できる。

## Questions

pull/外部 edit/未commit patch を検知できるか。破損 DB を正本だけから復旧できるか。query は source revision を正しく返すか。

## Prototype Scope

1k/10k/50k Layer で Git pull、branch switch、外部 edit、未commit patch、DB 破損を再現する。

## Out of Scope

SQLite を正本にする設計、永続 SQLite migration、全 query の最適化。

試作 code をそのまま production code に昇格させない。

## Measurements

query p50/p95、incremental/full rebuild 時間、drift 検出率、誤った query revision 数を記録する。

実行環境、fixture、command、実装 commit、raw data を記録する。必要なときだけ `artifacts/` を作成し、巨大な build output は commit しない。定量 budget は実験前に固定する。

## Success Criteria

破損時に正本から再構築でき、stale result を current と報告しない。

## Failure Criteria

stale result を current と返す、破損 index から再構築できない、または query/rebuild が事前 budget を超える。

## Result

未実施。実測値、観察、失敗、成果物への link を記入する。

## Conclusion

未実施。結果が ADR の Options と Current Hypothesis をどう変えたかを記入し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
