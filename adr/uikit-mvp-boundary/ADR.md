# UIKit Preview の MVP inclusion

## Context

UIKit は target として必要だが、controller/navigation の lifecycle を守る Host 実装の工数は未実測。MVP に含めるかは検証結果で判断する。

## Decision to Make

UIKit Host を MVP 必須 gate に含めるか、SwiftUI MVP 後の target とするか。

## Constraints

IR と Capability は UIKit を初期から区別する。UIKit の controller/navigation を rectangle に近似しない。

## Options

SwiftUI と同時提供、UIKit は limited alpha、UIKit は Phase 5。

## Current Hypothesis

**未確定:** UIKit Host は限定 node を runtime に構築できるが、MVP 同時提供の可否は navigation lifecycle と実装工数の実測次第。

## Unknowns

UIViewController containment と UINavigationController の変更範囲、Auto Layout warning、SwiftUI Host との開発コスト、初期 coverage。

## Required Evidence

[spikes/uikit-host-feasibility/SPIKE.md](spikes/uikit-host-feasibility/SPIKE.md) を実施し、観測値と結論を同じディレクトリに記録する。未実施の結果を確定判断として扱わない。

## Decision Criteria

[spikes/uikit-host-feasibility/SPIKE.md](spikes/uikit-host-feasibility/SPIKE.md) の成功・失敗基準に照らして選択肢を比較し、採用する方式と残る制約を記録する。判断と結果を commit した後に、必要な実装・検証と現行 docs への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Spike Required
