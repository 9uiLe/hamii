# Git / LFS threshold and availability

## Related Decision

[ADR.md](../../ADR.md) の「Repository Asset を通常 Git と LFS に振り分ける policy」を判断するための Evidence。

## Hypothesis

size/type に基づく振り分けで clone cost と asset availability を管理できる。

## Questions

どの閾値が実用的か。LFS object 欠落を open 前に検知できるか。重複内容を hash で共有できるか。

## Prototype Scope

小/大 binary と重複画像を複数 branch/clone で比較し、LFS absent collaborator を再現する。

## Out of Scope

Remote URL、runtime-bound binding、generated asset の採用。 試作 code を production code として扱わない。

## Measurements

repo/clone bytes、pull time、hash mismatch、欠落時の preflight。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

policy 候補が事前 budget を満たし、欠落と integrity error が診断される。

## Failure Criteria

欠落 object を無診断で開く、または clone cost が許容範囲を超える。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
