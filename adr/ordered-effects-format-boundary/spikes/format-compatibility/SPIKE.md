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

Environment: macOS 27 / Swift 6.4、旧/current-v1 production module は baseline `878cf929cd90c9c85a92e743d63af96f3dcd4bf7` と同一。計画 commit `1945c88ed1fe1381fdb69e937e673ae7340b5596` 後に test-only [4 cases](artifacts/OrderedEffectsFormatCompatibilitySpikeTests.swift) を実装・実行した。Project copy は CanonicalRepository が作った有効な Format v1 project で、実験では JSON bytes だけを test-only に編集した。4 tests は全件通過した。詳細な条件別結果は [compatibility-matrix.json](artifacts/compatibility-matrix.json)。

**v1 additive read-side:** `formatVersion=1` / `versions.document=1` の Screen root へ `effects=[padding,background]` を加えると、旧 `CanonicalRepository.load` と `observe` は成功した。Decoder が作った Layer とその再 encode には `effects` がなく、`TargetPlanner.plan` は `canPreview=true`、`SwiftUIGenerator` は追加前と完全に同じ source を返した。旧 consumer は新しい meaning を観測せずに成功できる。これは read-side silent semantic loss の実例であり、v1 additive 案の failure criterion に該当する。

**v1 additive write-side:** Effect 挿入後に取得した client precondition から unrelated `setText` を試すと、`CanonicalTransaction.preflight` が `screens/screen_probe.json` の exact-byte mismatch を `transactionConflict` として拒否した。Effect を含む Screen bytes と manifest bytes は試行前後で一致した。この条件では silent write drop は観測されなかった。これは read-side の不適合を解消しない。

**Version markers:** `1/2` は Repository の `load/observe` が `unsupportedFormat(1)` で止まる一方、`MigrationPreflight` は `current` と判定した。Partial marker は一致した migration boundary を作らない。`2/2` と negative control `2/1` は Repository が semantic use 前に `unsupportedFormat(2)` で止まり、observe / mutation は拒否された。Preflight は `sourceDocumentFormatVersion=2` / `noMigrationEdge` を返した。各 case で manifest と Screen の元 bytes は維持された。Preview / Generator は rejected project の repository load 後には呼び出していないため、「その path から semantic output は得られない」と記録する。

**Candidate order / migration seam:** Test-only `CandidateNode` は `padding(token)` と `background(token)` の配列順を Codable round-trip で保持し、A→B と B→A の値・encoded bytes は異なった。v1 の `layout.paddingTokenID` を candidate の単一 padding effect へ移し、no-padding、nested child、ComponentDefinition root、ComponentInstance reference の tested Layer subtree は元の v1 Layer へ復元できた。No-padding は tested subtree で `lossless`、padding 移設は `losslessWithNormalization` と分類する。これは **Layer subtree の局所変換** の Evidence であり、Document 全体の migration edge が lossless と証明されたわけではない。既存 v1 意味から effect order を推測する必要はこの corpus で観測されなかった。

Candidate の `effect.padding`、`effect.background`、`effect.order` を test-only requirement として抽出し、target declaration を Exact にしても consumer catalog が空なら共有 `CapabilityEvaluator` が全件 Unsupported で拒否した。Production `CapabilityKeys` や consumer support は増やしていない。`nativeIntent` / `targetOverrides` へ effect sequence の文字列を入れる negative control は DocumentValidator で一般 field として通るが、extractor は `native.intent` / `native.targetOverride` しか出さず、typed effect/order の契約にならない。

**Limits:** SIGKILL / power-loss、実 v2 parser、全 Canonical entity の migration、Preview Host 実描画、全 generator/lowering は対象外。Effect 挿入は非協調の test-only JSON 編集であり、通常の hamii writer contract ではない。今回は format boundary の観測に限定する。

## Conclusion

Spike の時点で v1 additive は旧 consumer が effect を落として成功するため semantic safety を満たさない。`versions.document` だけの bump も Repository / MigrationPreflight の判定が食い違う。Top-level `formatVersion=2` は検証した旧 reader path を semantic use 前に止め、migration edge 未設置を明示した。これらは明示的 Format v2 と migration boundary を ADR で判断する根拠になる。ただし production v2 representation と全 v1→v2 migration の correctness は未実装・未検証のままである。

## Artifacts

- [Machine-readable compatibility matrix](artifacts/compatibility-matrix.json)
- [Test-only legacy reader and candidate probes](artifacts/OrderedEffectsFormatCompatibilitySpikeTests.swift)（historical source。Current Format v2 の test target には含めない）
