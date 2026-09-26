# Android Native Preview の frame/input transport

## Context

Android Emulator 上の Compose Host を Native Preview abstraction に接続する方式は未検証。Frame streaming、input forwarding、headless lifecycle と複数 Emulator の資源消費が設計に影響する。

## Decision to Make

Compose Host の frame と input を macOS editor に運ぶ transport と lifecycle boundary を決める。

## Constraints

OS-dependent appearance は Android Runtime が描画する。通常 IR 編集で compile しない。Android Studio 内部 API への依存を前提にしない。

## Options

Emulator display capture + ADB input、Host 側 frame stream、別の公開 SDK 経路。

## Current Hypothesis

**未確定:** 公開 Emulator/ADB interface と Host protocol で成立する可能性がある。

## Unknowns

latency、frame loss、input 座標変換、headless reliability、複数 Emulator の memory/CPU。

## Required Evidence

[Frame and input feasibility](spikes/frame-input-feasibility/SPIKE.md) で小さな Compose Host を測定する。

## Decision Criteria

revision と frame の対応が検証でき、input が正しい Host event に届き、複数実行時の資源消費が許容範囲に収まる。

## Status

Spike Required
