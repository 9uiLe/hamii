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

**未確定:** Swift 6.4 の iOS Simulator 向け Runtime build と TCP Host probe の compile は成功した。**Blocked:** transport validation is currently blocked by an independent Simulator boot failure. `simctl boot` は Preview Host install / launch / TCP connection より前に失敗する。transport 自体の成功・失敗、latency、recovery は未測定。

## Unknowns

Simulator の接続経路、patch delivery と frame/update latency、disconnect / reconnect、Host restart / session recovery、schema mismatch、複数 Surface。CMIO XPC の停止原因は Simulator boot environment の blocker として Spike に記録し、この ADR の transport 採否とは分離する。

## Required Evidence

- [Host session and recovery](spikes/session-recovery/SPIKE.md)

## Decision Criteria

実際に起動した Host で connect、patch delivery、frame/update latency、disconnect、reconnect、Host restart、session recovery を測るまで transport を判断しない。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [preview-frame-capture](../preview-frame-capture/ADR.md)
- [preview-input-forwarding](../preview-input-forwarding/ADR.md)

## Status

Spike Required
