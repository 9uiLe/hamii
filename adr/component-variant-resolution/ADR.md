# Component Variant と Instance の解決

## Context

Variant の組合せが増えると保存量、override 競合、resolver cache、scope/capability validation の負荷が増える。

## Decision to Make

Definition/Variant/Instance を subtree copy なしで保存し、sparse delta と override をどの順に解決するか。

## Constraints

Scope owner は Definition に属する。Instance は公開された property/slot/path のみ override 可能。cycle は拒否。

## Options

全組合せ materialize、sparse variant delta、variant ごと別 Definition。

## Current Hypothesis

**未確定:** base tree + sparse deltas + typed override precedence で 1k instance を局所的に解決できる。

## Unknowns

selected Variant 同士の同一 path は現在 typed conflict になるが、その契約を採用するか。Variant → property → slot → allowed override の cross-stage precedence、特に slot が先行書込みの対象 Layer を消す場合の診断。nested Definition の再帰解決と cycle をこの Decision に含める境界。cache key / actual invalidation、variant explosion の閾値。

## Required Evidence

[spikes/instance-resolution/SPIKE.md](spikes/instance-resolution/SPIKE.md) に direct Resolver の 16 ケース、Current Canonical sparse save、1,000 Instance の raw resolve cost / 論理 affected output set、独立監査を記録した。slot replacement の silent loss、invalid combination の DocumentValidator / Canonical save、valid nested Definition の解決 / cycle、実際の局所再計算と同一 encoding boundary での保存量比較が未検証。これらを Decision 前に狭く検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Spike Required
