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

**未確定:** Effect は JSON の新しい field 以上の新 semantic なので v2 が有力。ただし旧 v1 reader の read-side / write-side 挙動、version marker の gate、candidate migration 分類を実測してから判断する。

## Unknowns

- v1 Layer shard の未知 `effects` を旧 reader が受理・無視するか。Preview / Generator は effect を落として成功するか。
- 旧 client の unrelated mutation が exact-byte preflight で止まるか、未知 field を消すか。
- `formatVersion` と `versions.document` を片方だけ進めた場合、CanonicalRepository と MigrationPreflight の判定が一致するか。
- v2 marker を旧 reader が semantic use 前に拒否し、元 bytes を保てるか。
- v1 の `layout.paddingTokenID`、nested / component tree を順序付き candidate へ lossless に写せるか。

## Required Evidence

- [Format compatibility Spike](spikes/format-compatibility/SPIKE.md) の事前登録 matrix、実 v1 reader / writer 検証、最小 test-only ordered effect round-trip、分類。
- 旧 reader baseline は commit `878cf929cd90c9c85a92e743d63af96f3dcd4bf7`。Production source を変更しない test-only 検証でその挙動を測る。

## Decision Criteria

旧 reader が新しい meaning を知らずに Preview / Generator 等を成功させる方式、または write 時に新 field を失う方式は採用しない。Version marker は Repository と migration preflight に一貫した境界を与えること。候補変換は順序と既存 v1 意味を保持し、曖昧さを隠さないこと。Spike の hard stop に達した案は棄却候補とし、判断には確認済み範囲と未検証範囲を分けて記録する。

## Status

Spike Required
