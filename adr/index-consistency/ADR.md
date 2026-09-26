# Local Query Index の鮮度判定

## Context

SQLite は再構築可能な検索用 index であり、Git 上の変更や branch 切替に追従しなければ誤った Query/AI context を返す。

## Decision to Make

Git pull、外部 edit、未commit mutation、branch switch に対する changed-entity detection と index revision protocol。

## Constraints

SQLite は disposable。stale query result を current と表示しない。

## Options

filesystem watcher + fingerprint、Git diff + working-tree fingerprint、full scan fallback。

## Current Hypothesis

**未確定:** Source revision だけでは不足することを Spike で確認した。Git HEAD + tracked diff + untracked content の digest は逐次 edit/commit switch を検出する。CLI はこの fingerprint を index metadata と照合し、通常の外部 edit を stale として拒否する。一方、nested Git repository 内の Starter Sample では query p95 321.9 ms となり、既存の 250 ms budget を超えた。同時書込時の正確性と増分再索引は未検証。

## Unknowns

filesystem watcher の取りこぼし、Git pull と concurrent external edit、query 中の revision 競合、symlink/filter の working bytes、複数 shard の大規模 untracked project、incremental rebuild の性能。fingerprint を index freshness の最終 protocol とするかは未決定。

## Required Evidence

- [Index drift and scale](spikes/index-drift/SPIKE.md): revision-only 判定の反例と 1k/10k/50k scale を確認。
- [Git working tree fingerprint](spikes/git-working-tree-fingerprint/SPIKE.md): 外部 edit、branch switch、dirty tree の digest と latency を検証する。
- [Nested repository query latency](spikes/nested-repository-query-latency/SPIKE.md): Git repository 内の下位 Project で query budget 超過を確認。

## Decision Criteria

[spikes/index-drift/SPIKE.md](spikes/index-drift/SPIKE.md) の成功・失敗基準に照らして選択肢を比較し、採用する方式と残る制約を記録する。判断と結果を commit した後に、必要な実装・検証と現行 docs への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Researching
