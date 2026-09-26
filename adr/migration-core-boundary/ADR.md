# Current Core と Historical Format の隔離

## Context

Current Core に旧 Format の parser や version branch が入ると、通常開発と AI context に legacy 互換コードが蓄積する。旧→Current 変換の module 境界はまだ実装で検証されていない。

## Decision to Make

Historical Format の parser と edge migrator をどの package/dependency 境界に置き、Current Core を Current Format のみに保つか。

## Constraints

Core は Current Format のみ理解する。Migration は旧 tree を元の場所で破壊しない。Document/Harness/Integration version は分離する。

## Options

別 package の historical parsers + edge registry、App 内の隔離 target、Core 内の compatibility branch。

## Current Hypothesis

**未確定:** historical parsers と edge migrators を Core 外の別 target に置き、Current Format を出力する方式が有力。

## Unknowns

edge graph の version 組合せ、historical type と current type の dependency 漏れ、途中 edge 失敗時の扱い、module 配布の単位。

## Required Evidence

- [Isolated format upgrade](spikes/isolated-format-upgrade/SPIKE.md)

## Decision Criteria

v1→v2→v3 の変換と検証を通し、Core の依存 graph に historical type が存在しないことを確認する。判断と結果を先に commit し、実装・検証と Current Architecture への反映を終えるまで削除しない。

## Related Decisions

- [migration-review-protocol](../migration-review-protocol/ADR.md)
- [migration-ambiguity-resolution](../migration-ambiguity-resolution/ADR.md)

## Status

Spike Required
