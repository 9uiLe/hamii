# CLI semantic command taxonomy

## Context

CLI は AI、CI、validation、migration、debugging に使う正式 interface。現在の command subset から capability、asset、preview、integration を増やすときの命名規則は未検証。安全性を保った開発 cycle の改善では、context payload / process latency と独立して、command discovery に必要な往復と読み込む live skill を評価する。

## Decision to Make

Command tree の resource/verb 配置、query と mutation の命名、skill discovery との対応を決める。

## Constraints

GUI と Application Service を共有し、CLI に独立した business rule を持たない。AI は installed skill で command を発見できる。構造化 output を持つ。

## Options

CURRENT の hybrid command tree を維持、resource-first tree、verb-first tree、task-oriented top-level commands。

## Current Hypothesis

候補比較の仮説は Evidence review を完了し、下記 Decision に移した。CURRENT は resource-oriented authoring と query / preview / integration / generation / migration / Git の semantic namespaces を組み合わせる hybrid であり、pure resource-first ではない。

## Unknowns

異なる model、広い task set、異なる skill 分割での一般性は未測定。今回の代表 workload の決定を妨げる必須追加 Spike はない。Structured error の recovery / retry は別の [CLI Error ADR](../cli-error-contract/ADR.md) の責務。

## Required Evidence

新規 Agent が bootstrap skill だけから代表的な authoring、query、validation、preview、integration、generation task を完了する観察と command discovery の失敗記録。[Agent command discovery Spike](spikes/agent-command-discovery/SPIKE.md) は CURRENT を含む4候補を test-only proxy で同じ production semantics へ接続し、各2回の fresh session を比較する。実測前に grammar、task、初期 prompt、順序、hard gate を固定する。

## Evidence Synthesis

Plan `c6b0298` / correction `e871d49` の exact-SHA CI 成功後に8 fresh session を実施した。Evidence は `4cf61aa16ada4168e2452c0a8417905c9af64b1f`、[Verify 36713057042 success](https://github.com/9uiLe/hamii/actions/runs/36713057042)。全試行の command-only audit、独立 oracle、失敗した preflight と修正を [analysis](spikes/agent-command-discovery/artifacts/trial-analysis.md) / [matrix](spikes/agent-command-discovery/artifacts/trial-matrix.json) に保持する。Production Sources は変更していない。

| Candidate | Task success | Undiscovered attempts | Usage / other errors | Discovery calls | Command attempts | Loaded skill bytes |
|---|---:|---:|---:|---:|---:|---:|
| CURRENT | 10/10 | 0 | 0 / 0 | 9 / 9 | 27 / 27 | 5,656 / 5,656 |
| RESOURCE | 10/10 | 0 | 0 / 0 | 9 / 9 | 27 / 27 | 5,682 / 5,682 |
| VERB | 10/10 | 0 | 0 / 0 | 9 / 9 | 27 / 28 | 5,757 / 5,757 |
| TASK | 10/10 | 0 | 0 / 0 | 9 / 9 | 27 / 27 | 5,806 / 5,806 |

全候補で同じ semantic skill groups を取得した。Primary discovery correctness / guessing / round-trip に material difference は観測していない。VERB-2 の1追加は context summary の重複取得で、集計に残す。

Authoritative runtime token median は CURRENT 440,951 / RESOURCE 432,945.5 / VERB 424,542 / TASK 393,677.5。Total は input + output のみで、cache / reasoning を重複加算しない。TASK が最小の observed agent-session total だが、n=2 / candidate、provider/cache variance 未制御、TASK range 39,837、whole development-cycle tokens / cost 未計測。一般的な token 削減率や開発費削減を主張しない。

Session wall median は CURRENT 171.403 / RESOURCE 162.045 / VERB 169.386 / TASK 154.710 seconds。Process launch から oracle 完了までの descriptive observation で、fixture / gate / CI / operator cycle は含まず、p95 / SLA / winner 判定には使わない。

Alternative adoption は既存 user/scripts の例、skill text、docs、smoke、automation、agent が学ぶ grammar の変更を伴う。Discovery-call / guessing / correctness の改善がない本測定では、TASK の低い token / wall 観測値だけでこの変更負担を正当化しない。

## Decision Criteria

正式 command が推測なしに発見でき、resource の所有関係と mutation boundary が名前から分かる。新 command は存在する近い semantic/resource namespace を拡張し、cross-resource operation に一律の global resource/verb/task grammar を強制しない。Production rename は compatibility / migration cost を正当化する具体的 Evidence が必要。

## Reopen Trigger

より広い fresh-agent workload で、discovery failure、discovery round-trip、または authoritative session token usage に再現可能な product 上の改善が観測され、command compatibility / migration cost を正当化できる場合に再評価する。別 model / task set での再現が必要になる可能性がある。今回未検証の数値 threshold は設けない。

## Decision

CURRENT の production CLI taxonomy を維持する。試験した RESOURCE / VERB / TASK への command tree rename は行わない。全候補が代表 task を推測 / error なしに、同じ discovery-call 数で完了した。TASK の低い observed token / wall 値だけでは compatibility / migration cost を正当化できない。

`hamii` CLI は唯一の AI/automation interface。Installed `skills list` / `skills get` が正式な command discovery mechanism であり、existing production namespaces を安定させる。新 command は近い existing semantic/resource namespace を拡張する。`query context` / `preview plan` / `integration contract` / `generate swiftui` のような cross-resource operation に global resource/verb/task rewrite を強制しない。Production rename は具体的な新 Evidence で正当化する。

全 command 表の正本は current source と live skills であり、ADR に複製しない。CURRENT 維持のための compatibility alias / migration は不要。Future taxonomy の再評価は Reopen Trigger に従う。

Decision Review は `31aa38885a5a54f09e1ffa9222341eb906db3e32`、[Verify 36716913744 success](https://github.com/9uiLe/hamii/actions/runs/36716913744) に保存済み。残る implementation は Current Architecture の恒久ルールと既存 CLI smoke での代表 namespace discovery regression、および full gate / exact-SHA CI と closure review。

## Status

Implementation Required
