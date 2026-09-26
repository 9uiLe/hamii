# Spike: Component Variant と Instance の解決

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 06 Component Variant に対応。

## Hypothesis

base tree + sparse deltas + typed override precedence で 1k instance を局所的に解決できる。

## Questions

定義変更は全 instance に伝わるか。単一 instance 更新は局所的か。衝突や cycle を診断できるか。

## Prototype Scope

複数 axis、重複 path、nested Definition、1k instance を持つ resolver prototype を作る。

## Out of Scope

Figma の全 variant UX、production source の全 target 対応。 試作 code をそのまま production code に昇格させない。

## Measurements

resolution p50/p95、invalidated instance 数、保存 bytes、競合/cycle diagnostic。 対象環境、fixture、command、実装 commit と raw data を記録する。必要な成果物のみ `artifacts/` に保存する。

## Success Criteria

subtree copy なし、定義変更の反映と局所 instance 更新が正しく、競合を拒否できる。

## Failure Criteria

局所変更が全 document 再解決を要する、または override 競合を黙って上書きする。

## Result

未実施。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

未実施。ADR の判断への影響を記録し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
