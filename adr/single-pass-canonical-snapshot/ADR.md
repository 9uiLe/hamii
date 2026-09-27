# CanonicalSnapshot の bytes 取得境界

## Context

CanonicalSnapshot は coordinated worktree read 中に Document を decode した後、Canonical JSON を再読込して content identity を作る。5000 Component の production profile では Snapshot p50 795.03 ms、entity bytes 初回読込 129.90 ms、identity bytes 再読込 177.05 ms だった。[Current Architecture](../../docs/final-architecture.md) の coordinated writer と fail-closed Index consistency を維持しながら、同じ bytes を decode と identity に用いられるかは未検証である。

## Decision to Make

CanonicalSnapshot の Document decode、Agent profile validation、content identity を、一つの coordinated observation で取得した各 Canonical JSON の同一 bytes から構築する単一パス方式を production に採用するか。

## Constraints

- 既存の root-based path discovery、keyed `String <` ordering、symlink rejection、WorktreeCoordinator lock、generation gate、identity hash algorithm を維持する。
- Shard の Document array は現在の folder 別 `lastPathComponent` order と一致させる。
- Agent profiles、Document validation、repository Asset integrity、filename/EntityID 検査の受理・拒否を維持する。
- Raw external writer の同一 worktree 並行変更は coordinated writer guarantee 外。Git oracle の鮮度判定は Snapshot に混ぜない。
- Candidate は test-only とし、成功 Evidence が揃う前に production path を変更しない。

## Options

1. 現在の decode / identity 再読込を維持する。
2. Canonical JSON の全 bytes を coordinated read 中に一度捕捉し、decode / validation / identity へ共有する。
3. ファイル記述子や OS snapshot primitive を用いて acquisition boundary 自体を変更する。

## Current Hypothesis

**未確定:** Option 2 は byte-coherence を明示し、5000 shard の lock hold を減らす可能性がある。全 Data と decoded Document の同時保持、エラー順序、Asset blob の扱いを測ってから判断する。Option 3 の必要性はこの Spike から推定しない。

## Unknowns

Test-only Spike は同一 bytes 性、per-folder order、検証した error category、stable generation / symlink gate、Snapshot・Phase 1・writer wait の局所計測を得た。Production への採用前には、保持した `Data` と decoded Document の同時利用による大規模 Project の peak memory、複数故障時の error priority、Index recovery の end-to-end 統合効果、CI の全体検証を評価する。非協調 writer の同時変更保証はこの Decision Boundary に含めない。

## Required Evidence

- [Byte-coherent acquisition Spike](spikes/byte-coherent-acquisition/SPIKE.md): test-only candidate の success/error/race/measurement 比較。検証したケースの結果は同 Spike に記録済み。
- Candidate と production の Document、ordered entity IDs、CanonicalSnapshotIdentity、diagnostics、stable generation 判定が一致すること。
- 1 / 1000 / 5000 / mixed fixture で読み込み回数・bytes・p50/p95・writer wait を測ること。

## Decision Criteria

各 Canonical JSON の decode bytes と identity bytes が同一で、各 file の成功時 read が1回、既存の受理・拒否と lock boundary が一致することを安全 gate とする。その上で Snapshot、Phase 1、writer wait、captured byte memory の便益と複雑さを比較する。いずれかの安全 gate が欠ければ採用しない。

## Status

Spike Required
