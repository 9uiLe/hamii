# Spike: Native-semantic IR の最小 taxonomy

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 01 IR に対応。

## Hypothesis

typed node + separate domain graph + target extension で主要 screen を loss-aware に記述できる。

## Questions

主要画面を opaque field に逃げず記述できるか。SwiftUI/UIKit/Compose で loss が説明できるか。stable ID と round-trip は成立するか。

## Prototype Scope

現行 `Layer`/`Screen` で4 fixtureを encoding し、その後 test-only の7種の typed payload、ordered effects、separate Component graph、screen system semantics、target extension、validator と serializer で同じ corpus を encoding する。Production `Model.swift` は変更しない。

## Out of Scope

全 framework API、native source import、production-ready editor。 試作 code をそのまま production code に昇格させない。

## Measurements

Swift 6.4 / macOS 27 SDK / arm64 上で `swift test --filter MinimalIRSpikeTests`。4 fixture × current/candidate encoding、round-trip、stable ID、child/effect order、malformed state の validator 結果を記録する。4 target の lowering は source generation ではなく documented conceptual classification として比較する。machine-readable corpus は `artifacts/corpus-matrix.json`。

## Success Criteria

4 fixture の required intent が typed portable semantics、explicit typed target extension、または explicit loss になる。generic bag required = 0、silent loss = 0。ordered effects と stable IDs が round-trip し、invalid combinations が型または validator により拒否され、Scope/Component/Token/Asset は visual node から分離される。4 target の loss matrix があり、Production `Model.swift` は不変。

## Failure Criteria

required intent が `nativeIntent`/`targetOverrides` だけを必要とする、effect order を失う、system bars が free-positioned Layer を必要とする、target-specific 分岐が portable payload を支配する、または loss が source generation まで露出しない。

## Result

2026-09-28 の focused test は **5 tests / 0 failures**。現行 `Layer`/`Screen` も4 fixtureを serialize/validate できたが、17 required intents のうち2件（ordered padding→background、SwiftUI detents）が generic string を必要とした。候補は同じ17件を typed payload/effect/screen semantics/separate graph/target extensionで表現し、generic bag required 0、candidate escape hatch use 0。4 fixtureが encode/decode 後に semantic equality と stable Screen/Component/root IDsを保持し、ordered effects の A→B/B→A は異なる encoding のまま round-trip した。

Current validator は Text+asset、eventless Button、2-root Scroll、unknown targetOverride key の4状態を受理した。候補は cross-kind payload と 2-root Scroll を型形状で除外し、missing asset/definition、empty Button/toolbar event、wrong target extension の5 probeを validator で拒否した。これらは corpus に限定した結果であり、production validator 全体の優劣を証明しない。

4 target × 17 intents の分類は [corpus-matrix.json](artifacts/corpus-matrix.json) にある。Apple system-image の Android mapping、Apple system navigation と Compose TopAppBar の ownership、SwiftUI-only detent extension の他 target 対応は explicit `unsupported`/`approximate` とした。これは lowering planであり、runtime parity/production generator 実測ではない。

Repository validation: `bash scripts/check.sh` は 217 tests / 56 intentional skips / 0 failures、および architecture、ADR、docs、CLI、merge、sample checks まで成功。`swift build -c release --product HamiiCore` も成功。いずれも test-only probe を含む同一 working tree で実行した。

## Conclusion

Selected corpusでは typed payload + ordered effects + separate graphs + explicit target extension の仮説を支持する。Current shapeの Screen-level system navigation、stable IDs、separate Component/Token/Asset graph は保持できる。一方、optional shared Layer payload、generic native intent/target override、effect orderの欠落は candidateより invalid-state pressure と loss表現が大きい。System Navigation/Toolbarは visual treeと別の Screen-level semanticsが適切という結果。詳細な API set、runtime lowering、migration はこの Spike の証明外。ADRの最終判断とproduction refactorは別段階で行う。

## Artifacts

- [corpus-matrix.json](artifacts/corpus-matrix.json): 17 intents × 4 targets、baseline/candidate representation と explicit loss。
- [taxonomy-comparison.md](artifacts/taxonomy-comparison.md): current/candidate 比較、invalid-state pressure、system UI ownership と primary framework docs。
- [MinimalIRSpikeTests.swift](artifacts/MinimalIRSpikeTests.swift): historical test-only prototype と5 focused XCTest。Current Format v2 の test target には含めない。
