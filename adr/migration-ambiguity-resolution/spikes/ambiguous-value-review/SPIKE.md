# Ambiguous value review

## Related Decision

[ADR.md](../../ADR.md) の「ambiguous/lossy migration の停止と解決」を判断するための Evidence。

## Hypothesis

Requires Resolution report は Human に必要な判断を示し、無言の loss を防げる。

## Questions

literal color に複数 token がある時どう提示するか。missing asset と unsupported component はどう block するか。

## Prototype Scope

color→token 複数候補、missing asset、unsupported component を fixture にして report と resolution を試す。

## Out of Scope

worktree isolation、全 schema version の edge 実装。 試作 code を production code として扱わない。

## Measurements

manual decision、候補/影響件数、report/diff、再実行結果。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

曖昧値を自動選択せず、未解決 item を漏れなく提示し、解決結果を再実行できる。

## Failure Criteria

silent guess、loss の非表示、または resolution を再実行できない。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
