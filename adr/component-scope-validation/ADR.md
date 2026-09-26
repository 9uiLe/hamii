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

**未確定:** 同一 evaluator と closure/index projection で Human/AI/Validator の判定を一致させられる。

## Unknowns

nested Definition の effective scope、promotion の再検証範囲、例外 policy の説明可能性。

## Required Evidence

[spikes/scope-rule-parity/SPIKE.md](spikes/scope-rule-parity/SPIKE.md) で検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Spike Required
