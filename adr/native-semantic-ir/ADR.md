# Native-semantic IR の最小 taxonomy

## Context

最初の node/field taxonomy が framework API の写しや汎用 property bag になると、後の Preview、生成、migration が不安定になる。

## Decision to Make

Text/Image/Button/Stack/Scroll/Navigation/Toolbar と ordered effects、target override を表す最小 Current IR の境界を決める。

## Constraints

Source of Truth は IR。Page/Scope/Component などの graph を Layer の万能 field に詰め込まない。Product 固有 architecture を入れない。

## Options

typed node と別 graph、汎用 property bag、framework-specific AST。

## Current Hypothesis

**未確定:** typed node + separate domain graph + target extension で主要 screen を loss-aware に記述できる。

## Unknowns

代表 screen corpus で不足する意味、ordered effects の最小形、target-specific extension の増加率。

## Required Evidence

[spikes/minimal-ir/SPIKE.md](spikes/minimal-ir/SPIKE.md) で検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Spike Required
