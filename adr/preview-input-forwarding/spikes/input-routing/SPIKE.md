# Preview input routing

## Related Decision

[ADR.md](../../ADR.md) の「Native Preview input forwarding」を判断するための Evidence。

## Hypothesis

Canvas の入力を Host の basic native control に転送できる。

## Questions

tap と keyboard focus は届くか。viewport scale/orientation で座標は正しいか。複数 Surface 間で混線しないか。

## Prototype Scope

Button/tap と TextField/focus の小さな Host fixture を使い、ズーム・回転・複数 Surface を試す。

## Out of Scope

複雑な multi-touch gesture、frame capture 方式、production app の全 interaction。 試作 code を production code として扱わない。

## Measurements

入力座標誤差、event trace、focus state、surface routing error。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

basic tap/focus が正しい target に届き、event trace が source revision と結びつく。

## Failure Criteria

入力が別 Surface に届く、座標がずれる、または event trace が欠落する。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
