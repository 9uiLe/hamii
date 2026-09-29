# Ordered Effects の Canonical Format 境界

## Context

[Native-semantic IR](../native-semantic-ir/ADR.md) は順序に意味がある typed effects を Current IR の設計境界として採用した。Spike 実施時の Format v1 の Layer JSON にはその永続表現がなかった。新しい意味を旧 reader が知らないまま受理すると、保存時の安全性とは別に Preview や Source Generator が意味を落として成功する可能性がある。

## Decision to Make

First-class ordered effects を永続化する際、Canonical Format v1 の additive extension で semantic safety を保てるか。それとも Document Format v2 と明示的な v1→v2 migration boundary が必要か。

## Constraints

- Current Core は Current Format のみ理解する。旧形式への runtime compatibility branch を増やさない。
- 未知の effect を旧 consumer が黙って落として Preview / Source / mutation を成功させない。
- 既存 v1 Canonical user data を破壊せず、移行分類と review が可能であること。
- `nativeIntent` や `targetOverrides` を通常の ordered semantic の property bag としない。
- Historical Spike は production Format、effect taxonomy、Preview / Generator lowering、migration implementation を変更せず測定した。

## Options

1. **Format v1 additive field:** Layer shard に `effects` を追加し、`formatVersion` と `versions.document` は 1 に保つ。旧 reader / writer / consumer の実挙動を検証する。
2. **Generic field reuse:** `nativeIntent` / `targetOverrides` 等に順序を encode する。Typed ordering、validator、capability extraction の境界に反する可能性を negative control として検証する。
3. **Explicit Format v2:** `formatVersion` と `versions.document` を明示的に進め、旧 reader は semantic use 前に拒否し、v1→v2 を migration subsystem で変換する。

## Current Hypothesis

**判断前の仮説:** Effect は JSON の新しい field 以上の新 semantic なので v2 が有力。旧 v1 reader の read-side / write-side 挙動、version marker の gate、candidate migration 分類を実測してから判断する。

## Unknowns

この Format Boundary の判断に残る未解決事項はない。Manual historical input は [migration-ambiguity-resolution](../migration-ambiguity-resolution/ADR.md)、他 effect と typed target extension は [native-semantic-ir](../native-semantic-ir/ADR.md)、consumer / runtime coverage は [capability-contract](../capability-contract/ADR.md)、power-loss durability は [canonical-power-loss-durability](../canonical-power-loss-durability/ADR.md) の境界に属する。

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

## Production Integration

Current Format v2 の ordered padding effect、validation、serialization、Canvas / Native Preview lowering、Generator の拒否を production に接続した。Foundation-only v1→v2 edge は全 Layer tree と capability declaration を変換し、cross-kind residual 等を manual blocker とする。`migrate prepare` は隔離 candidate を作成し、`migrate publish` は review した exact OID を CAS で公開、`migrate recover` は old/candidate/neither を区別する。他 effect の taxonomy と consumer coverage はこの Format Boundary の削除条件ではない。

## Closure Review

v1 additive による silent semantic loss を防ぐ明示的 Format v2 Decision を Current code / schema / validation / tests / README / `docs/final-architecture.md` が表現する。Required [Spike](spikes/format-compatibility/SPIKE.md) の Result と Decision は先行 commit に保存済み。Production v1→v2 edge、isolated candidate、CAS publication / recovery は `79e8b2cef2886c9305709891d771674c088f3359` までに実装・検証した。[Exact-SHA Verify run](https://github.com/9uiLe/hamii/actions/runs/36520669881) は成功した。Manual input は [migration-ambiguity-resolution](../migration-ambiguity-resolution/ADR.md)、他 effect / typed extension は [native-semantic-ir](../native-semantic-ir/ADR.md)、runtime coverage は [capability-contract](../capability-contract/ADR.md)、power-loss は [canonical-power-loss-durability](../canonical-power-loss-durability/ADR.md)、LFS object policy は [asset-storage-policy](../asset-storage-policy/ADR.md) に属する。この ADR の削除条件を満たす。

## Status

Implementation Required
