# Current Core と Historical Format の隔離

## Context

Current Core に旧 Format の parser や version branch が入ると、通常開発と AI context に legacy 互換コードが蓄積する。旧→Current 変換の module 境界はまだ実装で検証されていない。

## Decision to Make

Historical Format の parser と edge migrator をどの package/dependency 境界に置き、Current Core を Current Format のみに保つか。

## Constraints

Core は Current Format のみ理解する。Migration は旧 tree を元の場所で破壊しない。Document/Harness/Integration version は分離する。

## Options

別 package の historical parsers + edge registry、App 内の隔離 target、Core 内の compatibility branch。

## Current Hypothesis

解決済み。採用した境界は以下の Decision に記録する。

## Decision

Historical parser、versioned transformation edge、edge registry は `HamiiMigrations` の独立 target に置く。`HamiiMigrations` は `HamiiCore`、`HamiiFormat`、`HamiiIndex` を import せず、元の Canonical file bytes を受け取り、candidate file bytes と edge path / classification / diagnostics を返す。Current `Document` を historical edge の入力・出力型にしない。各 edge の後にその version の candidate を検証し、失敗時には candidate を公開せず元の Repository を変更しない。

Current Core は Current Format の意味だけを持つ。Migration orchestration は独立 target の候補を隔離領域で組み立て、Current Format に到達した後で Current Format / Core の semantic validation、fresh Index rebuild、review/publication を呼ぶ。Current Format の version gate を historical fallback に緩めない。Document、Authoring Harness、Integration Profile の version は独立して扱う。

この Decision は dependency と data-flow の境界である。Ordered effects の production Format v2 は Current reader/writer に実装済み。Foundation-only の production v1→v2 edge は `HamiiMigrations` に実装済みで、raw Canonical bytes を入力として返す。Migration executor、隔離 worktree の review/publication は未実装である。

## Unknowns

Installed historical edge は v1→v2 のみ。長期的な edge 配布単位、production executor、candidate の review/publication integration は未実装。Review/publication の判断は [migration-review-protocol](../migration-review-protocol/ADR.md) で扱う。Spike の test-only v3 は製品 version の提案ではない。

## Required Evidence

- [Isolated format upgrade](spikes/isolated-format-upgrade/SPIKE.md)

## Decision Criteria

Test-only v1→v2→v3 の各 edge 検証、決定性、元データの byte 不変、独立 target の依存方向、外側 harness の semantic oracle / fresh Index handoff は [Spike](spikes/isolated-format-upgrade/SPIKE.md) と [matrix](spikes/isolated-format-upgrade/artifacts/migration-matrix.json) で確認した。Full gate は 14 checks 成功、Swift test 243 実行・失敗 0・skip 56。Release `HamiiMigrations` build 成功。Evidence commit `6abeb2c90fa2ad4f846209260f77f1fcba71f9c2` の [exact-SHA CI](https://github.com/9uiLe/hamii/actions/runs/36498011848) は成功。これは production migration の完成証明ではない。

Decision と Evidence は先に Git history に残す。Production 実装・validation・Current Architecture への反映を終えるまで ADR は削除しない。

## Related Decisions

- [migration-review-protocol](../migration-review-protocol/ADR.md)
- [migration-ambiguity-resolution](../migration-ambiguity-resolution/ADR.md)

## Status

Implementation Required
