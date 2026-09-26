# CLI semantic command taxonomy

## Context

CLI は AI、CI、validation、migration、debugging に使う正式 interface。現在の command subset から capability、asset、preview、integration を増やすときの命名規則は未検証。

## Decision to Make

Command tree の resource/verb 配置、query と mutation の命名、skill discovery との対応を決める。

## Constraints

GUI と Application Service を共有し、CLI に独立した business rule を持たない。AI は installed skill で command を発見できる。構造化 output を持つ。

## Options

Resource-first tree、verb-first tree、task-oriented top-level commands。

## Current Hypothesis

**未確定:** resource-first tree は小さな Skill に分割しやすい。

## Unknowns

Target / Surface / Component / Integration の command が複数 resource にまたがる場合の一貫性、利用者が必要な Skill を見つける手数。

## Required Evidence

新規 Agent が bootstrap skill だけから代表的な authoring、query、validation、integration task を完了する観察と command discovery の失敗記録。

## Decision Criteria

正式 command が推測なしに発見でき、resource の所有関係と mutation boundary が名前から分かる。

## Status

Researching
