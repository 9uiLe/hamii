# Component Scope の共通検証境界

## Context

Human Picker、AI Query、Mutation Validator で許可結果が異なると architecture ownership を守れない。nested component と promotion で transitive dependency も増える。

## Decision to Make

ancestor-only rule、transitive dependency、availability exception、promotion をどの共通 evaluator で判定するか。

## Constraints

Page 階層と Scope は独立。sibling dependency は許さない。Promotion は architecture change として承認対象。

## Options

共通 Scope evaluator、各 consumer の独立判定、事前 materialized availability graph。

## Current Hypothesis

共通 evaluator を policy authority とし、SQLite availability はその派生 projection とする。nested deny、複数 allowOnly ID、unsafe / safe promotion の検証 fixture で Human / AI / Validator の判定が一致した。

## Decision

`allowOnlyScopeIDs` は列挙された consumer ArchitectureScope ID **本体だけ**を許す。descendant は暗黙に許可しない。`denyScopeIDs` も exact ID に適用する。owner が consumer 自身または ancestor でない場合は `scope.notAncestor`、deny に含まれる場合は `component.denied`、非空の allowOnly に含まれない場合は `component.notAllowed` とする。この順序と同じ判定を nested ComponentDefinition に再帰適用する。

判定の authority は `ComponentAvailability` に置く。Human Picker、AI query、Mutation Validator は同じ evaluator を使用し、SQLite availability は Canonical Document から得た派生結果とする。Promotion は architecture change として Agent の明示 permission を要し、owner 変更後の candidate Document 全体が Validator を通る場合にだけ保存する。

`allowOnly=[Commerce, Product]` は Commerce と Product を許し、Checkout を除外できる。descendant 解釈では Commerce を許した時点で Checkout も許すため、この区別ができない。exact 解釈は将来追加される descendant を自動許可せず、保存済み field の意味も変えない。subtree 許可が必要になれば別の明示的 policy を設計する。

Evidence: [`943471dd334d426525ade6f7a253eae8ff6adf7c`](https://github.com/9uiLe/hamii/commit/943471dd334d426525ade6f7a253eae8ff6adf7c) の [scope-rule-parity Spike](spikes/scope-rule-parity/SPIKE.md)。16行の scope/component matrix、Picker / AI context / SQLite / Human / Agent の判定一致、unsafe / safe promotion と full Index rebuild、4 / 1000 component の process 内観測値を記録した。測定は end-to-end SLA を示さない。

再評価するのは、実際の Product workflow で exact ID の列挙では親 Scope と特定 descendant の許可管理が成立しない、または大量の明示 ID 更新が具体的な障害になった evidence が得られた場合に限る。既存 field を黙って subtree semantics に読み替えない。

## Unknowns

例外 policy を Human / AI にどう説明するかが未実装。測定は small / 1000 components の process 内 availability / projection に限られ、Canonical read、SQLite Query、Git freshness を含まない。後者の性能と incremental Index invalidation は Index consistency ADR の対象。

## Required Evidence

[spikes/scope-rule-parity/SPIKE.md](spikes/scope-rule-parity/SPIKE.md) で検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Implementation Required
