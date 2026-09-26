# Remote cache and offline behavior

## Related Decision

[ADR.md](../../ADR.md) の「Remote Asset の cache と offline policy」を判断するための Evidence。

## Hypothesis

URL 正本と disposable cache で preview を成立させられる。

## Questions

cache 削除後に document は開くか。offline 時に何を表示するか。secret URL を拒否できるか。

## Prototype Scope

Remote URL 変更、offline、expiry、大画像、memory pressure、secret URL の fixtures を試す。

## Out of Scope

Git/LFS の閾値、production image loader の実装。 試作 code を production code として扱わない。

## Measurements

network requests、cache bytes、decoded memory、fallback time、stale behavior、secret rejection。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

cache 削除後も canonical data が有効で、offline fallback が明示され、secret URL が保存されない。

## Failure Criteria

cache が正本として必須、または秘密 URL が canonical file に残る。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
