# CanonicalSnapshot の bytes 取得境界

## Context

CanonicalSnapshot は coordinated worktree read 中に Document を decode した後、Canonical JSON を再読込して content identity を作る。5000 Component の production profile では Snapshot p50 795.03 ms、entity bytes 初回読込 129.90 ms、identity bytes 再読込 177.05 ms だった。[Current Architecture](../../docs/final-architecture.md) の coordinated writer と fail-closed Index consistency を維持しながら、同じ bytes を decode と identity に用いる方式を検証した。

## Decision to Make

CanonicalSnapshot の Document decode、Agent profile validation、content identity を、一つの coordinated observation で取得した各 Canonical JSON の同一 bytes から構築する単一パス方式を production に採用するか。

## Constraints

- 既存の root-based path discovery、keyed `String <` ordering、symlink rejection、WorktreeCoordinator lock、generation gate、identity hash algorithm を維持する。
- Shard の Document array は現在の folder 別 `lastPathComponent` order と一致させる。
- Agent profiles、Document validation、repository Asset integrity、filename/EntityID 検査の受理・拒否を維持する。
- Raw external writer の同一 worktree 並行変更は coordinated writer guarantee 外。Git oracle の鮮度判定は Snapshot に混ぜない。
- Production 実装では test-only Candidate をそのまま有効化せず、Snapshot 取得を一つの共通実装へ整理する。

## Options

1. 現在の decode / identity 再読込を維持する。
2. Canonical JSON の全 bytes を coordinated read 中に一度捕捉し、decode / validation / identity へ共有する。
3. ファイル記述子や OS snapshot primitive を用いて acquisition boundary 自体を変更する。

## Current Hypothesis

Spike 前の暫定仮説は、Option 2 が byte-coherence を明示し、5000 shard の lock hold を減らすというものだった。採用判断は下の Decision に記録する。Option 3 の必要性はこの Spike から推定しない。

## Unknowns

Production の Index recovery と save / generation / managed Git / validated merge 経路への統合効果、および採用後の end-to-end performance は実装時に検証する。大規模 Project の peak RSS は scaling measurement であり、この採用の correctness blocker ではない。現 CLI Error Contract は複数同時故障時の error precedence を固定していないため、単一故障の受理・拒否と主要 category の一致を採用 gate とする。非協調 writer の同時変更保証はこの Decision Boundary に含めない。

## Required Evidence

- [Byte-coherent acquisition Spike](spikes/byte-coherent-acquisition/SPIKE.md): test-only candidate の success/error/race/measurement 比較。検証したケースの結果は同 Spike に記録済み。
- Candidate と production の Document、ordered entity IDs、CanonicalSnapshotIdentity、diagnostics、stable generation 判定が一致すること。
- 1 / 1000 / 5000 / mixed fixture で読み込み回数・bytes・p50/p95・writer wait を測ること。

## Decision Criteria

各 Canonical JSON の decode bytes と identity bytes が同一で、各 file の成功時 read が1回、既存の受理・拒否と lock boundary が一致することを安全 gate とする。その上で Snapshot、Phase 1、writer wait、captured byte memory の便益と複雑さを比較する。いずれかの安全 gate が欠ければ採用しない。

## Decision

Option 2 を採用する。`c33ff94` と `05f6b64` の Verify success、および [Byte-coherent acquisition Spike](spikes/byte-coherent-acquisition/SPIKE.md) の parity / race / measurement Evidence を根拠とする。Production の CanonicalSnapshot は、一つの coordinated observation で既存の root-based path discovery、keyed `String <` ordering、symlink rejection を通し、各 Canonical JSON の bytes を一度だけ捕捉する。その同じ bytes から Manifest header/full、folder 別 `lastPathComponent` 順の entities、Agent profiles を decode / validate し、既存の relative path + bytes の length-prefixed SHA-256 algorithm で identity を算出する。Repository Asset blob integrity と filename / EntityID の検査も維持する。

`bytes used for decode == bytes used for Snapshot identity` を不変条件とする。CanonicalSnapshotIdentity、CanonicalGeneration、ClientPrecondition は別概念として保ち、Git freshness oracle を Snapshot に統合しない。大規模 Project の peak RSS は後続の性能・scale 評価で扱い、memory 改善を本 Decision の効果として主張しない。

## Status

Implementation Required
