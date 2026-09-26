# Remote Asset の正本と Cache policy

## Context

Remote Asset は URL 参照と取得画像の寿命が違い、offline preview と秘密情報の扱いが未確定。

## Decision to Make

Remote Asset の canonical metadata、local cache、offline fallback と secret URL policy を決める。

## Constraints

Remote 実体 cache は Git 正本にしない。Runtime-bound Asset は binding metadata のみ。

## Options

URL-only + disposable cache、明示 repository fallback、cache expiry policy。

## Current Hypothesis

**未確定:** URL を正本、取得実体を disposable cache とする可能性がある。

## Unknowns

offline fallback、cache eviction、URL の認証情報、stale image の表示。

## Required Evidence

- [Remote cache and offline behavior](spikes/offline-cache/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [asset-storage-policy](../asset-storage-policy/ADR.md)
- [generated-asset-adoption](../generated-asset-adoption/ADR.md)

## Status

Spike Required
