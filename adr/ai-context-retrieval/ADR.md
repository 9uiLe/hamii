# Scope-aware AI Context Retrieval

## Context

Document 全体を毎回 AI に渡すと context が増大し、利用不可 component や古い情報から誤 mutation を作る。

## Decision to Make

summary→detail、Scope filter、selection/viewport/recent changes をどの Query API と鮮度契約で提供するか。

## Constraints

AI は Document Store を直接 mutate しない。利用可 resource は共通 Scope evaluator に従う。Query result と patch は revision を持つ。

## Options

semantic staged query、raw files search、full document dump。

## Current Hypothesis

**未確定:** scope-aware projected query と on-demand visual context で全 document dump なしに主要 AI task を完了できる。

## Unknowns

summary の情報不足、query 回数、token 節約と task 成功率の trade-off、visual context が必要な条件。

## Required Evidence

[spikes/scope-aware-context/SPIKE.md](spikes/scope-aware-context/SPIKE.md) で検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Spike Required
