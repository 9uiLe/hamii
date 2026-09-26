# Authoring Harness の共通 policy 実行

## Context

Prompt だけの規則は Human と AI に同じ制約を適用できず、直接 mutation の抜け道を生む。

## Decision to Make

versioned Authoring Harness をどの mutation/validation boundary で実行し、waiver をどう記録するか。

## Constraints

Human/AI 共通 policy。Actor Harness の権限と Authoring Harness の製品ルールを分ける。

## Options

Mutation Engine 内の共通 evaluator、各 actor 側の precheck、prompt のみ。

## Current Hypothesis

**未確定:** typed rule ID/severity と共通 validator を Mutation Engine に置けば actor に依らず同じ拒否を返せる。

## Unknowns

policy 変更後の既存違反、waiver の有効範囲、validator latency、rule の拡張方法。

## Required Evidence

[spikes/actor-policy-parity/SPIKE.md](spikes/actor-policy-parity/SPIKE.md) で検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Spike Required
