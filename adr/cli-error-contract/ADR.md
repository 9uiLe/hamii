# CLI structured error と exit status

## Context

CLI は AI、CI、scripts の唯一の automation interface。現在の error category と exit code は動作するが、retry と user action に必要な長期契約を固定する証拠がない。

## Decision to Make

Machine-readable error category、diagnostic envelope、exit status の allocation と versioning rule を決める。

## Constraints

GUI と同じ Application Service を使う。Human output と JSON output を分離する。AI は prose parsing をしない。

## Options

少数の固定 exit code、category ごとの exit code、versioned error envelope。

## Current Hypothesis

**未確定:** stable error category と少数の exit code を組み合わせる。

## Unknowns

Approval、conflict、validation、unsupported target、migration-required の再試行可否と、script consumers に必要な互換保証期間。

## Required Evidence

CLI smoke と CI usage の error matrix、Agent による structured error retry behavior を検証する。

## Decision Criteria

利用者が prose parsing なしで成功・修正可能 error・再試行可能 error を区別できる。

## Status

Researching
