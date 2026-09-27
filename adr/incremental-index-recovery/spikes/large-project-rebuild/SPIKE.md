# Large project の index rebuild cost

## Related Decision

[Incremental Index Recovery ADR](../../ADR.md) の full rebuild と incremental reindex の performance crossover。Automatic full rebuild の recovery policy は [Current Architecture](../../../../docs/final-architecture.md) に記載する。

## Hypothesis

**Inferred, unverified:** full rebuild は中規模まで簡潔な復旧手段だが、非常に多い shard / dependency / usage を持つ Project では CLI latency とメモリ使用量が自動復旧の UX を制限する。

## Questions

- Layer 数、shard 数、Component / Scope / usage 数のどれが rebuild cost を支配するか。
- nested Git repository、untracked shard、dirty shard で fingerprint cost はどう変わるか。
- full rebuild と incremental reindex の crossover はどこか。
- DB schema mismatch から fresh rebuild する時間と peak storage は許容可能か。

## Prototype Scope

1k / 10k / 50k Layer の既存測定を基準に、shard 数と dependency 密度を独立に変えた再現可能な Canonical fixture を作る。full rebuild、fingerprint、query、必要なら incremental prototype を同じ環境で比較する。fixture が実 Project の分布を模していない限界を明記する。

## Out of Scope

推定値だけで production threshold を固定すること、測定せず自動 full rebuild を採用すること。

## Measurements

fixture topology、file 数と総 bytes、Layer / Scope / Component / usage 数、cold/warm の rebuild p50/p95、fingerprint p50/p95、query p50/p95、peak RSS、DB size、追加 generation storage。CLI 起動を含めるか分けるか記録する。

## Success Criteria

再現可能な規模別 cost curve と full / incremental 比較が得られ、stale 結果 0、partial generation の公開 0。少なくとも既存の 50k Layer 測定との差を説明できる。

## Failure Criteria

fixture の規模を変えても bottleneck を区別できない、測定の再現性がない、または rebuild 中に不完全な index が query に見える。

## Result

**Measured, pilot only:** macOS 26.2 / Git 2.52.0 で 1 Component = 1 JSON shard = 1 Layer の一時 Project を作り、mostly-untracked と all-tracked を比較した。今回の 100 / 1000 / 5000 mostly-untracked shard の CLI full rebuild 最大値（各 3 回）は 601.513 / 796.813 / 1847.825 ms、CLI query 最大値（各 5 回）は 290.499 / 257.768 / 474.091 ms。1000 / 5000 all-tracked shard の rebuild 最大値は 666.568 / 1129.586 ms、query 最大値は 195.980 / 229.511 ms。5 回の最大値を p95 の粗い推定としており、100 shard の 290.499 ms は他の 4 回より高い。5000 mostly-untracked shard の query は 250 ms budget を明確に超えた。前回 pilot の 5000 mostly-untracked query 最大値も 454.333 ms だった。dependency 密度、peak memory、incremental comparison は未測定。既存の 1k / 10k / 50k Layer full rebuild 23.387 / 130.058 / 593.740 ms は Layer を少数 shard に集約した別 fixture であり、直接の同条件比較ではない。

## Conclusion

この pilot では untracked shard が多い条件で fingerprint を含む query cost が増え、5000 shard で query budget を超えた。同じ 5000 shard でも all-tracked 条件は今回の 5 回で予算内だった。**Unknown:** 実 Project の tracked / dirty / untracked 分布、dependency density、memory、incremental との crossover。Incremental の適用 threshold は未決定。

## Artifacts

- [probe.py](artifacts/probe.py): 一時 Canonical fixture と CLI rebuild/query の pilot。
- [result.json](artifacts/result.json): raw latency と fixture 範囲。

dirty-shard / dependency / memory の matrix は未作成。
