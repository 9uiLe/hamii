# Capability の契約粒度

## Context

Target ごとの対応範囲を Human、AI、Preview、Generator が同じ基準で扱う必要がある。宣言粒度が粗いと loss を隠し、細かすぎると保守できない。

## Decision to Make

`node/property/semantic-contract` のどの粒度で target/runtime version ごとの Exact、Portable、Target-specific、Approximate、Unsupported、External Integration Required を宣言し、loss を block するか。

## Constraints

Unsupported を黙って近似しない。Canvas、Host、Generator、AI は同じ判定を使う。Product-specific handler / state mapping を hamii IR の built-in 実装として扱わない。個別 framework の未検証 API support を宣言しない。

## Options

Node 単位、property 単位、semantic contract 単位。Navigation/Toolbar/Remote Asset は複合 capability が必要。

## Current Hypothesis

**Decision:** IR から semantic requirements を抽出し、target/runtime profile に対して requirement 単位の support を評価し、共有 loss report を出す。Approved Approximate も loss を隠さない。Property metadata は requirement 抽出の入力になり得るが、判定単位は独立した意味とその integration obligation とする。Node 単位の一括 support を判定の正本にしない。

これは granularity と評価境界の決定であり、SwiftUI/UIKit/Compose の正確な supported API set の決定ではない。Production の `TargetPlanner` と `SwiftUIGenerator` は Current Format v2 の requirement 抽出・共有 evaluator へ接続済み。両者は異なる実装 catalog を持ち、未宣言・未実装の意味を拒否する。明示的な semantic key は basic node alias より優先し、`effect.padding` は `token.spacing` alias に継承されず、alias は event・binding・asset source 等にも拡張しない。Generator は runtime 未指定で評価する。macOS Canvas は選択した SwiftUI AppSurface について、Application の read-only assessment から同じ `CapabilityLossReport` と `TargetPlan` を Inspector に表示する。AI 等の残る consumer と framework support coverage は未実装。

## Unknowns

Current Format v2 で未実装の requirement 抽出範囲、runtime version 別の support 登録方法、残る consumer への loss report 接続、registry の更新時 validation。特定 framework の support set は別途一次資料・実行検証が必要。

## Required Evidence

[spikes/capability-granularity/SPIKE.md](spikes/capability-granularity/SPIKE.md) に oracle、14 row / 33 requirement の比較、Spike 実施時の Planner baseline、test-only Swift code、限界を記録した。Oracle は候補より先に Git commit `0f2694f` に保存した。Fixture extraction で発見した D root Stack の欠落を候補計測前に訂正した。

## Decision Criteria

採用候補は false positive = 0、四 consumer divergence = 0、silent approximation = 0。False negative、registry entry、変更増幅を比較する。今回の corpus では semantic-contract 候補が 0/0/0、node は false positive 9、property は 3。Production 実装では同じ hard gates を維持し、未検証 target support を Exact としない。

## Status

Implementation Required
