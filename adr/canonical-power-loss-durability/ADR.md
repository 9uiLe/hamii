# Canonical transaction power-loss durability

## Context

プロセス停止の journal recovery は検証済みだが、停電後に file content と directory rename がどの順で永続化されるかは別の保証である。Asset blob の metadata より先の耐久性も関わる。

## Decision to Make

Canonical transaction と repository asset blob の power-loss durability level、および `fsync` / `F_FULLFSYNC` の使用境界を決める。

## Constraints

Git files が正本。完了を報告した revision が停電後に torn graph になってはならない。Storage error は黙殺しない。

## Options

`fsync` file + directory、必要箇所の `F_FULLFSYNC`、APFS atomic replacement に依存する方式、明示的に weaker durability を契約する方式。

## Current Hypothesis

**未確定:** File と親 directory の同期を組み合わせる必要がある可能性が高い。Power cut に対する実測はない。

## Unknowns

APFS / external drive の差、directory sync と hardware cache の扱い、asset blob の commit ordering、write amplification。

## Required Evidence

Apple の file durability documentation と、可能なら disposable VM / test volume で power-cut 相当の復旧を計測する。実験が必要になれば本 ADR 内に focused Spike を追加する。

## Decision Criteria

保証する durability level と failure mode を具体化し、file・directory・blob の同期順を測定と一次資料で説明できること。

## Status

Researching
