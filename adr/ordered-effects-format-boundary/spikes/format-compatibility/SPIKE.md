# Format compatibility

## Related Decision

[Ordered Effects の Canonical Format 境界](../../ADR.md)。旧/current-v1 baseline は commit `878cf929cd90c9c85a92e743d63af96f3dcd4bf7`。

## Hypothesis

未知の `effects` を v1 shard に足すだけでは旧 semantic consumer が効果を知らずに成功できる可能性がある。明示的 v2 marker は旧 reader を semantic use 前に止められる可能性がある。どちらも実測まで未確定。

## Questions

- v1+unknown effects を load / observe すると、何が Document に現れ、Preview / Generator / inspect / mutation はどう振る舞うか。
- exact-byte preflight は unrelated mutation の unknown field drop を防ぐか。
- `formatVersion` / `versions.document` の 1/1、1/2、2/2、必要なら 2/1 で Repository と MigrationPreflight はどう判定するか。
- padding/background の順序と v1 paddingTokenID を test-only candidate で保持できるか。
- Generic field reuse は typed semantics / validation / capability extraction を満たすか。

## Prototype Scope

- 有効な v1 project の一時コピーへ test-only `effects` field と version marker を挿入する。Production source は baseline のまま使う。
- Legacy `CanonicalRepository.load/observe`、`TargetPlanner`、`SwiftUIGenerator`、`ProjectService.mutate`、`MigrationPreflight.plan` の実結果と元 bytes を確認する。
- Test-only の最小 ordered effect candidate は padding(token) と background(token) のみ。encode/decode 順序、semantic equality、v1→candidate 変換、capability seam を検証する。
- 結果を `artifacts/compatibility-matrix.json` とこの Spike に記録する。

## Out of Scope

Production Format / IR / migration / capability / Preview / Generator の変更、完全な effect taxonomy、typed target extension、UI、framework API support、migration review workflow の決定。

## Measurements

各 matrix case で `case`、`manifestFormatVersion`、`documentVersion`、`legacyLoad`、`legacySemanticObservation`、`legacyPreviewPlan`、`legacyGeneration`、`legacyMutationSave`、`bytesPreserved`、`migrationPreflightState`、`candidateRoundTrip`、`classification` を記録する。成功・失敗の error category、既存 file bytes の変化も残す。時間測定は今回の判断条件ではない。

## Success Criteria

- 実 v1 reader の unknown field read と旧 Preview / Generator の semantic behavior が確認できる。
- unrelated mutation と exact-byte preflight の結果を read-side と分けて確認できる。
- version marker matrix と MigrationPreflight の結果が揃う。
- v2 old-reader rejection と bytes preservation を確認できる。
- test-only candidate で effect A→B と B→A を区別し、no-padding / single-padding / nested-component tree の移行分類を出せる。
- 未実装 consumer catalog が新 semantic requirement を拒否することを確認できる。
- Production Format / ordered-effect API を変更せず、full gate と exact-SHA CI を通す。

## Failure Criteria

- v1 additive を旧 reader が受理し、effect を無視して Preview / Generator を成功させる場合は additive 案の semantic safety failure とする。
- 旧 mutation が未知 field を消して成功した場合は additive 案の即時 failure とする。
- 1/2 marker で Repository と MigrationPreflight の current 判定が異なる場合、partial marker 案を採用しない。
- 2/2 marker で旧 reader が semantic use へ進む場合、v2 production 実装前に version gate を再設計する。
- v1→candidate で人間の意図推測が必要なら [Migration ambiguity](../../../migration-ambiguity-resolution/ADR.md) へ handoff し、この Spike では規則を創作しない。
- Generic fields が必要になる候補は [Native-semantic IR Decision](../../../native-semantic-ir/ADR.md) と不整合として扱う。

## Result

未実施。

## Conclusion

未判断。

## Artifacts

実験後に `artifacts/compatibility-matrix.json` を作成する。計測前の artifact は作らない。
