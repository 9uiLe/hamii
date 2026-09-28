# Ordered Effects の Canonical Format 境界

## Context

[Native-semantic IR](../native-semantic-ir/ADR.md) は順序に意味がある typed effects を Current IR の設計境界として採用した。現行 Format v1 の Layer JSON にはその永続表現がない。新しい意味を旧 reader が知らないまま受理すると、保存時の安全性とは別に Preview や Source Generator が意味を落として成功する可能性がある。

## Decision to Make

First-class ordered effects を永続化する際、Canonical Format v1 の additive extension で semantic safety を保てるか。それとも Document Format v2 と明示的な v1→v2 migration boundary が必要か。

## Constraints

- Current Core は Current Format のみ理解する。旧形式への runtime compatibility branch を増やさない。
- 未知の effect を旧 consumer が黙って落として Preview / Source / mutation を成功させない。
- 既存 v1 Canonical user data を破壊せず、移行分類と review が可能であること。
- `nativeIntent` や `targetOverrides` を通常の ordered semantic の property bag としない。
- 今回は production Format、effect taxonomy、Preview / Generator lowering、migration implementation を変更しない。

## Options

1. **Format v1 additive field:** Layer shard に `effects` を追加し、`formatVersion` と `versions.document` は 1 に保つ。旧 reader / writer / consumer の実挙動を検証する。
2. **Generic field reuse:** `nativeIntent` / `targetOverrides` 等に順序を encode する。Typed ordering、validator、capability extraction の境界に反する可能性を negative control として検証する。
3. **Explicit Format v2:** `formatVersion` と `versions.document` を明示的に進め、旧 reader は semantic use 前に拒否し、v1→v2 を migration subsystem で変換する。

## Current Hypothesis

**判断前の仮説:** Effect は JSON の新しい field 以上の新 semantic なので v2 が有力。旧 v1 reader の read-side / write-side 挙動、version marker の gate、candidate migration 分類を実測してから判断する。

## Unknowns

- 全 Canonical entity を対象にする v1→v2 migration edge の分類、曖昧さの有無、Core と historical parser の依存境界。
- Current Format v2 の typed effect schema、validation、全 consumer の未対応意味に対する fail-closed behavior。
- v2 publication / review / power-loss durability と既存 user repository の安全な移行手順。

## Required Evidence

- [Format compatibility Spike](spikes/format-compatibility/SPIKE.md) の事前登録 matrix、実 v1 reader / writer 検証、最小 test-only ordered effect round-trip、分類。
- 旧 reader baseline は commit `878cf929cd90c9c85a92e743d63af96f3dcd4bf7`。Production source を変更しない test-only 検証でその挙動を測る。
- Spike の test-only Evidence は commit `edd7a9278329aeffae0cee375a86471b213fa431` に保存され、[exact-SHA Verify run](https://github.com/9uiLe/hamii/actions/runs/36455546360) は成功した。4 focused cases、full gate 14 checks、242 tests 実行、56 skipped、0 failed。局所 candidate の限界は Spike に明記した。

## Decision Criteria

旧 reader が新しい meaning を知らずに Preview / Generator 等を成功させる方式、または write 時に新 field を失う方式は採用しない。Version marker は Repository と migration preflight に一貫した境界を与えること。候補変換は順序と既存 v1 意味を保持し、曖昧さを隠さないこと。Spike の hard stop に達した案は棄却候補とし、判断には確認済み範囲と未検証範囲を分けて記録する。

## Decision

**Ordered effects の Canonical 永続化には明示的な Document Format v2 境界を必要とする。** Current Format v1 の `formatVersion=1` / `versions.document=1` のまま `effects` を Layer shard に追加する方式は採用しない。`nativeIntent` / `targetOverrides` へ effect sequence を encode する方式も採用しない。Production v2 schema の具体的な field taxonomy と migration edge の実装はこの判断に含めない。

根拠は [Spike](spikes/format-compatibility/SPIKE.md) の実 v1 behavior にある。旧 Repository は v1+unknown `effects` を `load/observe` でき、旧 Preview は `canPreview=true`、旧 SwiftUI Generator は effect 挿入前と同一 source を返した。旧 client の unrelated mutation は exact-byte `transactionConflict` で止まり、テストした bytes は保たれたが、write-side の防御では read-side silent semantic loss を防げない。

`formatVersion=1` / `versions.document=2` は Repository が拒否する一方、MigrationPreflight は `current` と扱ったため、片方の marker だけを進める方式は採用しない。検証した `formatVersion=2` / `versions.document=2` では旧 Repository が semantic use 前に拒否し、MigrationPreflight が `sourceDocumentFormatVersion=2` / `noMigrationEdge` を返した。これは **旧 reader の fail-closed gate** の Evidence であり、新 v2 reader、migration edge、power-loss、全 consumer lowering の完成証明ではない。

Test-only candidate は padding/background の順序を round-trip で保ち、v1 `paddingTokenID` を単一 padding effect へ局所的に写した。No-padding、single-padding、nested Component subtree で tested Layer 意味は復元可能だった。全 Document の移行分類は未確定であり、曖昧な既存意味が見つかれば [migration-ambiguity-resolution](../migration-ambiguity-resolution/ADR.md) で扱う。

## Remaining Implementation

- [migration-core-boundary](../migration-core-boundary/ADR.md) で v1 historical parser と v1→v2 edge の隔離境界を検証・決定する。
- [migration-review-protocol](../migration-review-protocol/ADR.md) で元 user data を保つ review / publication 手順を決める。
- Current Format v2 の typed ordered-effect representation、validation、serialization と v1→v2 transformation を実装・検証する。新しい v2 meaning は consumer catalog が未対応なら fail closed にする。
- Current Architecture、samples、CLI、Preview、Generator の必要な契約を production 実装に合わせて更新する。この ADR は実装・検証・migration/review path 完了まで削除しない。

## Status

Implementation Required
