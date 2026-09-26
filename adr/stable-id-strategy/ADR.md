# Stable ID と semantic path の生成規則

## Context

Stable ID は Git diff、cross-file reference、semantic merge、mutation patch の基盤。現在の生成は UUID を使うが、同時編集と subtree copy 時の振る舞いは測定していない。

## Decision to Make

Entity/Layer ID の生成・複製・衝突処理と property path の安定性ルールを決める。

## Constraints

File path/name 変更で ID を変えない。Human と AI に同じ規則を適用。Canonical Format と Swift source identifier を分離する。

## Options

Random UUID、time-sortable ID、content-derived ID、entity type prefix と random suffix の併用。

## Current Hypothesis

**未確定:** type prefix + random UUID は衝突を避けやすいが、semantic merge に最適とは限らない。

## Unknowns

Copy/paste の identity、同時 branch での衝突率、large document query locality、path migration。

## Required Evidence

[Concurrent edit identities](spikes/concurrent-edit-identities/SPIKE.md) で merge fixture を比較する。

## Decision Criteria

Rename と move で ID が安定し、copy で新 ID を割り当て、merge conflict と query cost が許容できる。

## Status

Spike Required
