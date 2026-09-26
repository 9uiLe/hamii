# Local Query Index の自動復旧と世代公開

## Context

Git Repository の分割 JSON は共有 Canonical Data であり、Local SQLite は `~/Library/Application Support/hamii/indexes/` に置く再構築可能な私有の Materialized Query View である。Index を Git で共有しないことと、stale な index から検索結果を返さないことは確定した製品ルールである。現在は `CanonicalRevision` mismatch 時に `staleIndex` を返して検索を拒否する。この fail-closed behavior を自動復旧の検証中も維持する。Canonical Format migration と使い捨て Index schema rebuild は別責務である。

## Decision to Make

外部変更の検出後、どの changed-entity / dependency invalidation protocol で index を再生成し、完成した index generation を検索側へ atomic に公開して自動復旧するか。現在の Git-based revision calculation と手動 full rebuild を最終方式として固定しない。

## Constraints

Canonical Data が唯一の正本。途中まで再構築した世代を検索へ見せない。どの候補でも検証不能・競合・鮮度不一致なら検索を拒否する。Git 操作と再索引の同時実行を通常の逐次変更と区別する。

## Options

検知後の手動 full rebuild、検知後の自動 full rebuild、reverse dependency をたどる incremental reindex。watcher / Git status / fingerprint は changed-entity detection の候補であり、公開方式は別に比較する。

## Current Hypothesis

**未確定:** 自動復旧は `Canonical Data → Index generation → atomic publish` の順で作り、失敗時は旧世代を current として扱わず検索を拒否する方式が有力。**Confirmed:** revision のみでは外部編集後の stale result を返す。現在の Canonical revision mismatch は検索を拒否する。1 種類の Git clean filter では、Git の transformed representation が変わらず working Canonical bytes の変更を status から観測できない反例があり、現行 guard はその状態を `staleIndex` として拒否する。Git filter のある Repository 全般が設計上不可能とは結論しない。最初の Git status 後に branch を切り替える制御された race では、guard 前に旧 hit を返し、最後の status を再照合する guard 後は `staleIndex` を返した。これは任意の同時外部書込を保証しない。**Measured:** Starter Sample の CLI query p95 は別々の 40-run で 303.429 / 353.228 / 305.880 ms、追加 status guard 後の 40-run では 404.611 ms（すべて 250 ms 比較基準超過）。3 Git subprocess の in-process 計測は guard 前に各 p95 約 99～106 ms。run 間の差を index 配置や guard の厳密な効果と断定しない。5000 mostly-untracked Component shard の 2 pilot では query の 5 回最大値が 454.333 / 474.091 ms で予算超過。5000 all-tracked shard の pilot では 229.511 ms だったが、これは filter guard 追加前の測定。**Confirmed within tested sequential scenarios:** 外部編集、staging、untracked file、branch switch、`assume-unchanged` / `skip-worktree` flag、上記 clean filter を検出または拒否した。任意の同時 Git 操作・一般的な大規模 Project・自動復旧は未検証。

## Unknowns

安全な Canonical freshness 判定を Query ごとに 4 Git subprocess 相当の cost を負わず実現する方法、Canonical files が同じでも Repository HEAD だけが変わる場合の不要な失効、最終 check 後を含む同時外部書込の保証境界、自動 full rebuild と incremental reindex の UX / performance、reverse dependencies と affected derived indexes、Git 操作中の generation の一貫性、Git flag/filter guard の大規模 shard での cost、他の Git filter / attributes、symlink、非常に多い shard、巨大 Project の rebuild cost。現行 Git-based revision calculation / rebuild policy を最終 protocol とするかは未決定。

## Required Evidence

- [Index drift and scale](spikes/index-drift/SPIKE.md): revision-only 判定の反例と 1k/10k/50k scale を確認。
- [Git working tree fingerprint](spikes/git-working-tree-fingerprint/SPIKE.md): 外部 edit、branch switch、dirty tree の digest と latency を検証する。
- [Nested repository query latency](spikes/nested-repository-query-latency/SPIKE.md): Git repository 内の下位 Project で query budget 超過を確認。
- [Single-process Git fingerprint](spikes/single-process-git-fingerprint/SPIKE.md): porcelain v2 と dirty bytes の低 latency 候補を検証する。
- [Incremental reindex](spikes/incremental-reindex/SPIKE.md): 合成 graph で reverse dependencies と atomic generation publish を確認。実際の derived indexes は未実装・未測定。
- [Concurrent Git mutation](spikes/concurrent-git-mutation/SPIKE.md): hidden Git flags と clean filter の逐次反例、および最初の status 後の branch switch race を確認した。ほかの同時 Git 操作は未測定。
- [Low-cost freshness](spikes/low-cost-freshness/SPIKE.md): Starter Sample で CLI と Git subprocess の cost を分解。低 cost 候補の correctness は未測定。
- [Large project rebuild](spikes/large-project-rebuild/SPIKE.md): mostly-untracked と all-tracked Component shard の pilot を測定。dirty shard と dependency / memory matrix は未測定。

## Decision Criteria

必要な Spike で正確性、検索拒否、公開原子性、UX、latency、rebuild cost を比較した後に自動復旧方式を決める。検証前に現行 fingerprint / 手動 rebuild を最終方式としない。判断と結果を commit した後に実装・検証する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Spike Required
