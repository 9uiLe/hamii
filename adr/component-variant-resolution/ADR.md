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

複数 axis が同じ path を変更した時の precedence、cache key/invalidation、variant explosion の閾値。

## Required Evidence

[spikes/instance-resolution/SPIKE.md](spikes/instance-resolution/SPIKE.md) で検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Spike Required
