# Custom Native Component の Preview artifact 更新

## Context

custom source 変更は事前 compile 済み Host の値 patch と異なる。部分 build/relink/install の境界は未確定。

## Decision to Make

Custom Native Component の build artifact を Host にどう取り込み、いつ build/install/restart を要求するか。

## Constraints

任意 native source の runtime interpretation をしない。署名と platform lifecycle を守る。GUI edit で暗黙 full build を起動しない。

## Options

Host 再 build/install、別 artifact loading、placeholder + full validation。

## Current Hypothesis

**未確定:** 明示 build required が安全な既定値だが、軽い artifact 更新の可否は未実証。

## Unknowns

署名、dynamic loading、state loss、最小 build 単位。

## Required Evidence

- [Custom Component artifact update](spikes/artifact-update/SPIKE.md)

## Decision Criteria

Spike の結果を用いて選択肢を比較し、判断を先に commit する。必要な実装・検証と Current Architecture への反映を終えるまで削除しない。

## Status

Spike Required
