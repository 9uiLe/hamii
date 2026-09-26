# External Git writes during Canonical save

## Context

hamii 内の lock は Git CLI や他の editor に強制できない。外部書込が journal apply 中に入ると、同じ Canonical tree に複数 actor の変更が交錯する。

## Decision to Make

hamii の multi-file save と外部 Git checkout/pull/edit が同時に起きた場合の検出、復旧、ユーザー向け conflict protocol を決める。

## Constraints

外部 bytes を無断上書きしない。Git repository は共有正本であり、hamii のみが file system を所有する前提にしない。

## Options

pre/post working-tree fingerprint + conflict、Git operation adapter と file lock、temporary worktree staging、semantic merge boundary。

## Current Hypothesis

**未確定:** Journal に記録した旧新 bytes 以外を復旧時に conflict とする方式は、逐次外部編集の誤上書きを防げる。最小 APFS interleaving probe では content check と atomic replace の間の非協調 edit が上書きされ、旧新 journal から復旧不能だった。外部 Git operation を含む協調境界と conflict protocol は未決定。

## Unknowns

checkout/pull の interleaving、同じ bytes へ収束する編集、Git hooks/IDE の協調可能性、conflict UX、複数プロセスの lock semantics。非協調 writer への lossless 保証を提供できない境界を UI/CLI でどう表現するか。

## Required Evidence

- [External writer interleaving](spikes/external-writer-interleaving/SPIKE.md): check と atomic replace の間の非協調 writer を検証する。
- Git checkout/pull の各 apply 段階への注入と協調 protocol は引き続き検証する。

## Decision Criteria

外部変更を黙って失わないこと、復旧が再実行可能であること、ユーザーが conflict の解決対象を特定できること。

## Status

Spike Required
