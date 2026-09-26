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

**未確定:** Git/working-tree fingerprint と source revision で、disposable SQLite index の鮮度と再構築を管理できる。

## Unknowns

filesystem watcher の取りこぼし、branch switch の invalidation 範囲、大規模 rebuild 時間、query 中の revision 競合。

## Required Evidence

[spikes/index-drift/SPIKE.md](spikes/index-drift/SPIKE.md) を実施し、観測値と結論を同じディレクトリに記録する。未実施の結果を確定判断として扱わない。

## Decision Criteria

[spikes/index-drift/SPIKE.md](spikes/index-drift/SPIKE.md) の成功・失敗基準に照らして選択肢を比較し、採用する方式と残る制約を記録する。判断と結果を commit した後に、必要な実装・検証と現行 docs への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Spike Required
