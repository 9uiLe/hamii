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

これは granularity と評価境界の決定であり、SwiftUI/UIKit/Compose の正確な supported API set の決定ではない。Production の `TargetPlanner` と `SwiftUIGenerator` は Current Format v2 の requirement 抽出・共有 evaluator へ接続済み。両者は異なる実装 catalog を持ち、未宣言・未実装の意味を拒否する。明示的な semantic key は basic node alias より優先し、`effect.padding` は `token.spacing` alias に継承されず、alias は event・binding・asset source 等にも拡張しない。Generator は runtime 未指定で評価する。macOS Canvas は選択した SwiftUI AppSurface について、Application の read-only assessment から同じ `CapabilityLossReport` と `TargetPlan` を Inspector に表示する。AI は同じ assessment を Application context projection と CLI の one-shot / session surface detail から上限付きで取得する。Native Preview catalog の現在の適用 profile は macOS SwiftUI のみで、その他は Exact 宣言でも coverage 未登録として拒否する。Generator の iOS/macOS SwiftUI 境界は別に維持する。

## Unknowns

Current Format v2 の既知 built-in semantic requirement に未登録のものはない。将来の runtime version 別 support 方法は、具体的な version-sensitive requirement が確認された時に判断する。追加 framework/profile は将来の機能実装であり、一次資料・実行検証なしに support を登録しない。現在の catalog は runtime version 固有の support を宣言していない。

## Required Evidence

[spikes/capability-granularity/SPIKE.md](spikes/capability-granularity/SPIKE.md) に oracle、14 row / 33 requirement の比較、Spike 実施時の Planner baseline、test-only Swift code、限界を記録した。Oracle は候補より先に Git commit `0f2694f` に保存した。Fixture extraction で発見した D root Stack の欠落を候補計測前に訂正した。

Production では共有 semantic evaluator を `TargetPlanner`、`SwiftUIGenerator`、Human Canvas、AI context に接続した。Native Preview の適用 profile は macOS SwiftUI に限定し、未登録 profile は Exact 宣言でも拒否する。Built-in semantic key と alias は `CapabilityRegistry` へ集約し、実 extractor corpus と両 production catalog の整合性を permanent test で検証する。未登録の抽出意味は診断付きで拒否し、保存済み target declaration の未知 key は許可する。

## Decision Criteria

採用候補は false positive = 0、四 consumer divergence = 0、silent approximation = 0。False negative、registry entry、変更増幅を比較する。今回の corpus では semantic-contract 候補が 0/0/0、node は false positive 9、property は 3。Production 実装では同じ hard gates を維持し、未検証 target support を Exact としない。

## Status

Implementation Required

## Closure Review

Decision と Spike は完了し、現行 IR の意味に対する production 実装と検証も完了した。共有 extractor/evaluator は `TargetPlanner`、`SwiftUIGenerator`、Human Canvas の `SurfaceCapabilityAssessmentService`、AI の context projection に接続されている。Native Preview は macOS SwiftUI profile のみ適用し、その他の profile は宣言が Exact でも fail closed に拒否する。

`CapabilityRegistry` は25個の built-in semantic key を定義する。恒久テストの current extractor corpus は、その全 key を実 IR から発行し、registry 外の key を発行しない。両 production catalog は registry validation を通り、legacy alias は basic visual semantics のみを表す。未登録の抽出意味は error diagnostic とともに要求として保持し、保存済み target declaration の未知 key は拒否しない。現行両 production catalog の `runtimeSensitiveKeys` は空である。未指定 runtime で runtime-sensitive key を許可しない evaluator のテストも維持する。

現行契約には runtime version 別 support table が必要な concrete requirement はない。将来、一次資料と実行結果が runtime による差を示した semantic、nonempty `runtimeSensitiveKeys`、追加 framework/profile の実装、既存 requirement/evaluator/loss model で表現できない新しい意味、consumer 間で共有できない support semantics、または registry テストが示す consumer divergence が現れた場合は、その具体的な境界を再検討する。現在の decision boundary に未実装・未検証の follow-up は残っていない。

Evidence と Decision は [granularity Spike](spikes/capability-granularity/SPIKE.md) と Git history に残る。主な implementation history は `12a2f76` (shared Surface assessment)、`791c23c` (Canvas Inspector)、`3c387a4` (context projection)、`dd64b5d` (AI CLI context)、`e612681` (Preview profile gate)、`d4ba0cc` (profile regression)、`2f57a9c` (registry validation)、`9d5259a` (extractor/catalog coverage) である。恒久ルールは production code、tests、README、`docs/final-architecture.md`、`docs/implementation-status.md` に移した。Evidence 専用の `CapabilityGranularitySpikeTests` と Spike artifacts は Git history へ残し、ADR 削除 commit で current tree から除く。ADR と Spike の記録を独立 commit に残した後、別 commit でこの directory を削除できる。
