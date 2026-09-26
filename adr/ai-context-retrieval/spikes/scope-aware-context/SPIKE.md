# Spike: Scope-aware AI Context Retrieval

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 13 AI Context に対応。

## Hypothesis

scope-aware projected query と on-demand visual context で全 document dump なしに主要 AI task を完了できる。

## Questions

選択編集・component 探索・token 更新を小 context で完了できるか。stale revision を検出できるか。

## Prototype Scope

1k/10k node fixture で Query API と Agent Harness retrieval strategy を試作し代表 task を実行する。

## Out of Scope

Agent model の学習、GUI automation、全 repository code の検索。 試作 code をそのまま production code に昇格させない。

## Measurements

task success、送信 bytes/tokens、query count、scope violation、stale conflict。 対象環境、fixture、command、実装 commit と raw data を記録する。必要な成果物のみ `artifacts/` に保存する。

## Success Criteria

代表 task が全 document dump なしに完了し、scope violation と stale overwrite が発生しない。

## Failure Criteria

情報欠落による誤 edit が多い、または context が document サイズに比例して増える。

## Result

未実施。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

未実施。ADR の判断への影響を記録し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
