# Local Query Index の自動復旧と世代公開

## Context

Git Repository の分割 JSON は共有 Canonical Data であり、Local SQLite は `~/Library/Application Support/hamii/indexes/` に置く再構築可能な私有の Materialized Query View である。Index を Git で共有しないことと、stale な index から検索結果を返さないことは確定した製品ルールである。現在は `CanonicalRevision` mismatch 時に `staleIndex` を返して検索を拒否する。この fail-closed behavior を自動復旧の検証中も維持する。Canonical Format migration と使い捨て Index schema rebuild は別責務である。`CanonicalRevision` algorithm より先に、「同一時点の何を観測したか」を表す `CanonicalSnapshot` 境界を検証する。

## Decision to Make

stale result を返さない安全性を維持したまま、Canonical freshness 判定と Index recovery をどこまで低コスト・低失効で実現できるか。外部変更の検出後、どの changed-entity / dependency invalidation protocol で index を再生成し、完成した generation を検索側へ atomic に公開するかを含む。現在の Git-based revision calculation と手動 full rebuild を最終方式として固定しない。

## Constraints

Canonical Data が唯一の正本。`CanonicalSnapshot` は exact contents、source metadata、observation guarantee を持ち、その一貫した contents から `CanonicalRevision` を導出する。`CanonicalRevision` は hamii Canonical Data の意味的な状態、`IndexGeneration` は公開済みの derived snapshot であり別概念。Git commit だけが変わり Canonical files が同じなら、その commit 自体を意味的な失効理由にしない。途中まで再構築した世代を検索へ見せない。どの候補でも検証不能・競合・鮮度不一致なら検索を拒否する。Git 操作と再索引の同時実行を通常の逐次変更と区別する。外部 writer の分離・統合方式は [External Git Write ADR](../git-external-write-coordination/ADR.md) で扱う。

## Options

検知後の手動 full rebuild、検知後の自動 full rebuild、reverse dependency をたどる incremental reindex。鮮度判定には、現在の guarded Git、working Canonical bytes、path-scoped Git identity、fast check の確実な `current` と不確実時の slow verification を候補として比較する。watcher / Git status / fingerprint は changed-entity detection の候補であり、公開方式は別に比較する。Unsafe な size/mtime 単独判定は false negative 反例を持つ。

## Current Hypothesis

**未確定:** 自動復旧は `Canonical Data → Index generation → atomic publish` の順で作り、失敗時は旧世代を current として扱わず検索を拒否する方式が有力。**Confirmed:** revision のみでは外部編集後の stale result を返す。現在の Canonical revision mismatch は検索を拒否する。1 種類の Git clean filter では、Git の transformed representation が変わらず working Canonical bytes の変更を status から観測できない反例があり、現行 guard はその状態を `staleIndex` として拒否する。Git filter のある Repository 全般が設計上不可能とは結論しない。最初の Git status 後に branch を切り替える制御された race では、guard 前に旧 hit を返し、最後の status を再照合する guard 後は `staleIndex` を返した。これは任意の同時外部書込を保証しない。**Measured:** Starter Sample の CLI query p95 は別々の 40-run で 303.429 / 353.228 / 305.880 ms、追加 status guard 後の 40-run では 404.611 ms（すべて 250 ms 比較基準超過）。新しい disposable Starter copy の 40-run では fresh query p95 418.612 ms、stale detection p95 424.174 ms、full rebuild p95 1316.333 ms（20-run）。3 Git subprocess の in-process 計測は guard 前に各 p95 約 99～106 ms。run 間の差を index 配置や guard の厳密な効果と断定しない。5000 mostly-untracked Component shard の 2 pilot では query の 5 回最大値が 454.333 / 474.091 ms で予算超過。5000 all-tracked shard の pilot では 229.511 ms だったが、これは filter guard 追加前の測定。**Confirmed within tested sequential scenarios:** 外部編集、staging、untracked file、branch switch、`assume-unchanged` / `skip-worktree` flag、上記 clean filter を検出または拒否した。全 bytes 二重走査は制御された同時書込で2回の digest が一致しても存在しなかった複数 file 状態を返したため、単独では安全な snapshot protocol にならない。実 `IndexProjection` rows を使う generation prototype は tested barriers で partial rows を公開しなかったが、production では未実装。任意の同時 Git 操作・一般的な大規模 Project・自動復旧は未検証。

## Unknowns

安全な Canonical freshness 判定を Query ごとに 4 Git subprocess 相当の cost を負わず実現する方法、Canonical files が同じでも Repository HEAD だけが変わる場合の不要な失効、確実な fast-path `current` 条件と slow verification protocol、複数 Canonical file の一貫した snapshot、最終 check 後を含む同時外部書込の保証境界、自動 full rebuild と incremental reindex の end-to-end UX / performance、stored reverse dependencies と targeted projection 計算、Git 操作中の generation の一貫性、Git flag/filter guard の大規模 shard での cost、他の Git filter / attributes、symlink、非常に多い shard、巨大 Project の rebuild cost。現行 Git-based revision calculation / rebuild policy を最終 protocol とするかは未決定。

## Required Evidence

- [Index drift and scale](spikes/index-drift/SPIKE.md): revision-only 判定の反例と 1k/10k/50k scale を確認。
- [Consistent CanonicalSnapshot](spikes/consistent-canonical-snapshot/SPIKE.md): hamii-owned lock 下の reader/save 境界と pinned Git tree の保証範囲を確認。非協調 writer を含む current working tree の coherent snapshot は未解決。
- [Safe freshness fast path](spikes/safe-freshness-fast-path/SPIKE.md): manifest + metadata shortcut の false negative を確認。`certainly current` の安全な一般条件と slow verifier は未確定。
- [End-to-end Index generation](spikes/end-to-end-index-generation/SPIKE.md): current full pipeline の15回 stage timing。Snapshot acquisition と production incremental generation を接続した end-to-end 測定は未完了。
- [Git working tree fingerprint](spikes/git-working-tree-fingerprint/SPIKE.md): 外部 edit、branch switch、dirty tree の digest と latency を検証する。
- [Nested repository query latency](spikes/nested-repository-query-latency/SPIKE.md): Git repository 内の下位 Project で query budget 超過を確認。
- [Single-process Git fingerprint](spikes/single-process-git-fingerprint/SPIKE.md): porcelain v2 と dirty bytes の低 latency 候補を検証する。
- [Incremental reindex](spikes/incremental-reindex/SPIKE.md): 実 `IndexProjection` rows の changed/affected key と full oracle の一致、試作 SQLite generation の commit/rollback reader barrier、実 `LocalIndex` query 中の branch switch を確認。Production incremental projector と coherent source snapshot は未実装・未検証。
- [Concurrent Git mutation](spikes/concurrent-git-mutation/SPIKE.md): hidden Git flags と clean filter の逐次反例、および最初の status 後の branch switch race を確認した。ほかの同時 Git 操作は未測定。
- [Low-cost freshness](spikes/low-cost-freshness/SPIKE.md): Starter Sample で CLI と Git subprocess の cost を分解。8～5000 shard の fixture で現行 Git、double byte scan、size/mtime を比較し、Starter copy の CLI fresh/stale/rebuild を測定。size/mtime の逐次 false negative と double scan の同時書込 false negative を再現した。安全な fast/slow path は未確定。
- [Large project rebuild](spikes/large-project-rebuild/SPIKE.md): mostly-untracked と all-tracked Component shard の pilot を測定。dirty shard と dependency / memory matrix は未測定。

## Decision Criteria

必要な Spike で correctness（特に false negative）、false-positive invalidation、検索拒否、公開原子性、fast/slow path、UX、query / stale detection / full / incremental rebuild latency、branch switch、external edit、Git filter、大規模 scaling、implementation complexity を比較した後に方式を決める。250 ms は現時点の CLI query 比較基準であり Product SLA ではない。検証前に現行 fingerprint / 手動 rebuild を最終方式としない。判断と結果を commit した後に実装・検証する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Spike Required
