# Preview Host の IPC / session protocol

## Context

Editor と Simulator 内 Host の間では revision 付き patch を順序通り送る必要がある。切断後の同期失敗は stale Preview を生む。

## Decision to Make

Host との IPC transport、session/ack、再接続・複数 Surface routing の方式を決める。

## Constraints

`LoadSnapshot`、`ApplyPatch(baseRev,newRev)`、`Ack` と full resync を扱う。Simulator.app の window 埋込に依存しない。

## Options

local socket、Network framework connection、別の supported IPC/stream。

## Current Hypothesis

**未確定:** Swift 6.4 の iOS Simulator 向け Runtime build と TCP Host probe の compile は成功した。Simulator 起動が CoreSimulatorService 接続断で止まり、session の実測は未完了。Transport は未確定。

## Unknowns

Simulator の接続経路、欠番検出、Host suspend/restart、schema mismatch、複数 Surface。Simulator 起動環境の復旧後、Transport の実測が必要。

## Required Evidence

- [Host session and recovery](spikes/session-recovery/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [preview-frame-capture](../preview-frame-capture/ADR.md)
- [preview-input-forwarding](../preview-input-forwarding/ADR.md)

## Status

Spike Required
