# Nested Git repository query latency

## Related Decision

[Local Query Index の鮮度判定](../../ADR.md) の fingerprint cost と query freshness protocol の Evidence。

## Hypothesis

Git repository の下位 directory にある Project でも、source fingerprint を照合する query は既存の 250 ms p95 budget 内で完了する。

## Questions

Nested project の Git status cost と Swift `Process` 呼出を含む cold CLI latency はどの程度か。

## Prototype Scope

この repository 内の `Samples/Starter` を使い、`hamii index rebuild` 後に `hamii query components` を 8 回実行する。fingerprint は query の最後に 1 回計算する。

## Out of Scope

増分再索引、FSEvents、複数 project の同時 query、Git filter/symlink、production 実装の選択。

## Measurements

CLI 起動込み p50/p95、Git command 単体時間。判定 budget は [Git working tree fingerprint Spike](../git-working-tree-fingerprint/SPIKE.md) の 250 ms p95 を採用し、測定後に変更しない。

## Success Criteria

8 回の CLI query の p95 が 250 ms 以下で、検索結果が current source と一致する。

## Failure Criteria

p95 が 250 ms を超える、または stale result を返す。

## Result

macOS 26.2、Swift 6.4、Git 2.52.0 で、`Samples/Starter` の 8 回の query は 269.9、280.4、287.4、321.9、291.4、285.8、302.1、291.4 ms。p95 は 321.9 ms で budget を超えた。Git の `rev-parse`、`diff`、`ls-files` を Python subprocess で単独実行した時間は 6.9、6.7、7.7 ms だった。3 回の fingerprint を 1 回へ削減する前は同じ Sample の query が 866.7～1011.1 ms だった。外部編集後の `staleIndex` は CLI smoke で確認済み。

## Conclusion

Nested Project における現在の Git subprocess fingerprint は correctness guard として動くが、既存の query latency budget を満たさない。ADR では別の fingerprint 実装、Process overhead、増分索引、concurrent write を合わせて検証する必要がある。50k Layer の単一独立 repository で得た 65 ms p95 を一般化できない。

## Artifacts

- [probe.py](artifacts/probe.py): Starter Sample の cold CLI query を再測定する script。
- [result.json](artifacts/result.json): 今回の raw observations。
