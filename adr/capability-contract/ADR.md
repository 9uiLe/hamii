# Capability の契約粒度

## Context

Target ごとの対応範囲を Human、AI、Preview、Generator が同じ基準で扱う必要がある。宣言粒度が粗いと loss を隠し、細かすぎると保守できない。

## Decision to Make

`feature/property/target/runtime version` のどの粒度で Exact、Portable、Approximate 等を宣言し、loss を block するか。

## Constraints

Unsupported を黙って近似しない。Canvas、Host、Generator、AI は同じ判定を使う。

## Options

node 単位、property 単位、semantic contract 単位。Navigation/Toolbar/Remote Asset は複合 capability が必要。

## Current Hypothesis

**未確定:** feature/property/target/runtime の組合せに対する shared registry で、silent approximation を防ぎつつ保守可能な loss report を出せる。

## Unknowns

node/property/semantic contract の適切な粒度、複合機能の評価方法、OS version 差、registry の保守費。

## Required Evidence

[spikes/capability-granularity/SPIKE.md](spikes/capability-granularity/SPIKE.md) を実施し、観測値と結論を同じディレクトリに記録する。未実施の結果を確定判断として扱わない。

## Decision Criteria

[spikes/capability-granularity/SPIKE.md](spikes/capability-granularity/SPIKE.md) の成功・失敗基準に照らして選択肢を比較し、採用する方式と残る制約を記録する。判断と結果を commit した後に、必要な実装・検証と現行 docs への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Spike Required
