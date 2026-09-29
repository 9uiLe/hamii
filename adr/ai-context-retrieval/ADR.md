# Scope-aware AI Context Retrieval

## Context

Document 全体を毎回 AI に渡すと context が増大し、利用不可 Component や古い情報から誤 mutation を作る。Semantic authoring task に必要な情報を bounded response で取得する境界が必要です。

## Decision to Make

AI / CLI に Scope-aware な semantic authoring context を、どの情報開示方式と observation 契約で提供するか。Visual context、viewport capture、recent-change feed、具体的な CLI command taxonomy はこの判断の対象外です。

## Constraints

AI は Document Store を直接 mutate しない。利用可 resource は共通 Scope evaluator に従う。取得した context は exact observation の `ClientPrecondition` を持ち、`DocumentRevision` を state identity として使わない。Mutation は共通 Application Service で再検証する。Projection の出力が小さくても、Canonical observation と Query の安全性を省略しない。

## Options

semantic staged query、raw Canonical shard retrieval、full Document dump。

## Current Hypothesis

**当初の暫定仮説:** Scope-aware な bounded Query を既存の Canonical observation 上に実装すれば、Spike で確認した semantic information sufficiency を production CLI でも保てる。Production の correctness と payload は実装・検証済み。AI 総トークンへの効果は未計測であり、この Decision Boundary の完了条件にはしない。

## Unknowns

Selected Screen 内の 1k / 10k Layer の payload と service / CLI 時間は production で測定済み。さらに大きい Scope / Component / Token 集合、visual context、実際の LLM task success と総トークンは対象外。Canonical observation の内部 cost は独立した performance 調査で分解する。これらを Spike の payload 結果から推定しない。

## Required Evidence

[spikes/scope-aware-context/SPIKE.md](spikes/scope-aware-context/SPIKE.md) の precommitted oracle と 1k / 10k fixture を使い、FULL、STAGED、RAW の payload、query count、Scope、stale-state correctness を比較する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の precommitted 成功/失敗基準、local full gate、Evidence commit の exact-SHA CI に照らして semantic context の方式を選ぶ。実装では同じ Scope / availability oracle と `ClientPrecondition` を維持し、performance と LLM task success は別に測る。必要な実装・検証を完了してから恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Decision

代表的な semantic authoring task の AI context には **STAGED** を採用する。Project / Screen / Scope の bounded summary から始め、選択された Screen / Layer の semantic detail、consumer Scope で利用可能な resource summary、必要な Component / Token detail を段階的に取得する。通常の AI workflow に full Document dump や raw Canonical shard 読みを要求しない。

各 response は観測基点の `ClientPrecondition` と `DocumentRevision` を区別して提示する。複数 response の observation が一致しない場合は一つの current context として結合しない。Mutation は返された precondition を共通 `ProjectService` で再照合し、Scope / availability を同じ Authoring policy で検証する。Index は候補探索に利用できるが、その行だけを resource 利用可否の根拠にしない。

根拠は [scope-aware context Spike](spikes/scope-aware-context/SPIKE.md) の deterministic solver、real ProjectService mutation、Scope oracle、Current-format shard reader、および [30 行の測定 matrix](spikes/scope-aware-context/artifacts/context-matrix.json) である。1k / 10k Layer の五 task × 三 strategy はすべて必要情報・mutation・Scope / stale 条件を満たした。10k の FULL は 1,535,023 bytes、STAGED は task ごとに 2,138–2,977 bytes / 2–4 responses だった。追加 9k Layer は選択 Screen の外に置いた条件であり、この数値を一般的な payload 上限へ拡張しない。AI 総トークン、LLM task success、production Query 計算時間、visual context は未計測である。

Production implementation では bounded query の Current Snapshot / precondition binding、Scope-aware summary/detail、CLI structured output、複数 response 間の stale handling、semantic mutation までの end-to-end validation が必要である。Visual authoring context と具体的な CLI command taxonomy はこの Decision の対象外とする。

## Implementation Evidence

`ProjectContextService`、CLI `query context`、`skills get context`、共通 Scope availability、単一 observation と stale-state regression は production 経路に接続した。[Production measurement](../../docs/ai-context-query-performance.md) は 1k / 10k Layer の実 CLI payload と service / one-shot CLI timing を記録する。10k の T2 は staged 2,864 bytes / 4 responses、FULL 1,680,339 bytes / 1 response で、one-shot CLI workflow 中央値は 496.050 ms、FULL inspect は 196.819 ms だった。Spike の test-only payload 値を production 値として使わない。

## Closure Review

- Decision commit: `06aeb2ca78bfb592cf8f9b899fec8716cb713f0b`。STAGED と exact observation contract を選択した。
- Production implementation commit: `25225798c9c5e16a99edb15d88345aad1e208ebe`。Exact-SHA [CI run 36553487936](https://github.com/9uiLe/hamii/actions/runs/36553487936) success。Semantic T1/T2/T3 mutation、Scope / Availability、single-observation、same-revision stale-state rejection、bounded output、structured CLI、skill を確認した。
- Production measurement commit: `3a5e2483da0f43f35733f4b8bb6bc443e82e2843`。Exact-SHA [CI run 36556523786](https://github.com/9uiLe/hamii/actions/runs/36556523786) success。Production payload と service / one-shot CLI 時間を測定した。AI 総トークンと LLM task success は未計測と明記した。
- Current contract は `ProjectContextService`、CLI / skill、tests、[Current Architecture](../../docs/final-architecture.md)、[README](../../README.md)、[Implementation Status](../../docs/implementation-status.md) だけで理解できる。ADR は runtime の依存先ではない。
- Visual context、LLM/provider task success、実 AI 総トークンはこの semantic retrieval Decision Boundary の外側に残す。One-shot staged CLI の latency は測定した独立性能課題であり、STAGED / FULL / RAW の semantic correctness 判断を再開しない。Canonical observation の内訳を測ってから最適化方針を検討する。

Decision、Spike、production implementation、validation、現行文書への反映は完了した。Closure Evidence を独立 commit として Git history に残し、その exact-SHA CI 成功後の別 commit で ADR を削除する。

## Status

Implementation Required
