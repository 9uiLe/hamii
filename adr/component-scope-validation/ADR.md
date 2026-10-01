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

**未確定:** 共通 evaluator と SQLite projection は nested deny、複数 allowOnly ID、unsafe / safe promotion の検証 fixture で Human / AI / Validator と一致した。`allowOnly` の Product Semantics は exact consumer membership と descendant membership で結果が分かれるため、まだ選択しない。

## Unknowns

`allowOnly` の列挙 Scope だけを許すか descendant へ及ぶか、例外 policy を Human / AI にどう説明するか。測定は small / 1000 components の process 内 availability / projection に限られ、Canonical read、SQLite Query、Git freshness を含まない。

## Required Evidence

[spikes/scope-rule-parity/SPIKE.md](spikes/scope-rule-parity/SPIKE.md) で検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Ready for Decision
