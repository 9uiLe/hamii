# Spike: Slot replacement と write conflict の境界

## Related Decision

[Component Variant と Instance の解決](../../ADR.md) の cross-stage precedence。先行する [instance-resolution Spike](../instance-resolution/SPIKE.md) は slot replacement が選択済み Variant / instance property の書込み先を消しても Resolver が成功する反例を記録した。

## Hypothesis

slot replacement が元の Definition tree から除去する **strict descendant** への selected write を、解決前に typed conflict として拒否できる。slot target 自身、対象外 subtree、未選択 Variant を誤って拒否しない。ただし、現行 text path の対象は Text/Button、slot target は container なので、target 自身への text write は Current IR では表現できない可能性がある。

## Questions

現行 Resolver と DocumentValidator / CanonicalRepository は slot による書込み消失をどこまで許すか。sequential、明示 slot-wins、conflict-reject の各 semantics は同一 fixture をどう分類するか。empty replacement と nested slot でも strict descendant を一意に判定できるか。nested Definition の cycle safety は別 validation 境界にあるか。

## Prototype Scope

production Resolver / Validator を直接呼ぶ固定 fixture と、test-only の descendant 判定 / typed `slotWriteConflict(path, slotName)` evaluator を作る。selected Variant、instance property、allowed override、対象外 write、未選択 Variant、empty/nonempty slot、nested slot を比較する。実 Document と CanonicalRepository の保存 / reopen、valid nested Definition、cycle も検証する。独立監査は probe の raw fixture と結果から行う。

## Out of Scope

production `Sources/` / `Tests/HamiiTests/` の変更、production error enum、再帰的 Definition materialization、slot API の全面設計、cache / performance の最終判断。

## Measurements

source commit は `0376e79b1d9e1969cf3beaa5047dbd599bf79703`。macOS 27.0 arm64 / Swift 6.4。A は Current Resolver と 2 つの test-only evaluator を同じ固定 fixture の 13 ケースで比較し、tree ancestry の構造対照を記録する。B は別の有効な Current Document を使い、11 ケースを直接 Resolver、`DocumentValidator.validate`、`CanonicalRepository.commit` / reopen で測る。拒否時は Canonical JSON の path→bytes 前後一致を確認する。nested Definition の A→B と A→B→A も同じ保存境界で検証する。raw result と再実行 command は各 artifact に記録する。test-only evaluator の結果を production behavior と混同しない。

## Success Criteria

消失する descendant write と維持される write を stable ID の tree ancestry で区別し、selected/unselected、empty/nonempty、nested slot の対照ケースで誤判定がない。valid nested Document と cycle rejection の責務を実呼び出しで確認できる。現行の保存境界と候補 semantics の差を示し、ADR の Decision に必要な範囲を絞れる。

## Failure Criteria

descendant 判定が一意でない、合法な対象外 write を conflict と扱う、未選択 Variant を conflict と扱う、または valid nested Document と cycle の validation 境界を分離できない。fixture が Current Format の有効な Document でないのに production 保存の結果として扱う。

## Result

### Confirmed: Current production boundary

B の有効な Document fixture では、選択済み Variant / instance property が selected slot の旧 child に書いても、その子を replacement で消した後に Resolver は成功し、DocumentValidator diagnostics は 0、Canonical commit と reopen も成功した。empty `slotContent` も子を消す置換として同じ結果になった。nested container 内の text path も outer slot 置換で消えた。対象外 sibling への write は残り、slot 未選択時の書込みも残った。Variant 未選択・slot 選択の対照ケースも commit / reopen できたが、旧 child 自体が消えるため、resolved tree だけから dormant Variant の非適用を直接観察する対照ではない。

slot 後の allowed override が消えた child path を触るケースは Resolver が `unknownPath`、Validator が `component.resolution` とし、Canonical commit は拒否した。slot container 自身の `.text` write は Current IR の有効な操作ではなく、`component.variantPath` / `component.resolution` で拒否された。拒否された 2 ケースでは Canonical JSON の path→bytes が保存試行前後で一致した（各 787 bytes）。これらは固定 fixture の正常な単一 process save 境界の Evidence であり、concurrent writer / power-loss 保証ではない。

有効な A→B nested Definition Document は検証・保存・reopen でき、直接 `ComponentResolver.resolve(A)` は B を参照 node のまま返した。B→A を追加した cycle は `component.cycle` 診断で Canonical commit が拒否され、旧 Canonical JSON の path→bytes は一致した（4,041 bytes）。nested recursive materialization は直接 Resolver の責務ではないことを支持する固定ケースである。

### Compared: test-only semantics

A の 13 ケースでは、Current sequential semantics は selected Variant / property が消える path に書いても成功、後段 allowed override は `unknownPath`。試験用 `slotWins` は対象 write を明示的に抑制し、試験用 `conflictReject` は strict descendant に対して `slotWriteConflict(path,slotName)` を返した。別 path、未選択 Variant、empty / nonempty replacement を区別し、exact EntityID による ancestry 対照では slot target 自身を strict descendant から除外できた。inner / outer の nested slot が両方選択された場合、試作は最短距離の `inner` を報告したが、diagnostic owner の Product rule を決めたわけではない。A の fixture は unsupported な `slotTargetText` API path も含むため、有効な whole Document または Canonical 保存の証拠ではない。

**重要な反例:** 素朴な `slotWins` は、非公開 allowed override を filter して現行の `forbiddenOverride` を消し、同一 path を書く 2 selected Variant を filter して `conflictingVariants` も消した。素朴な `conflictReject` はこれらより先に `slotWriteConflict` を返した。したがって両 test-only evaluator は既存の拒否 / error priority を維持できず、そのまま production へ採用できない。最初の A prototype は no-conflict fallthrough 欠落で 4 ケース失敗し、修正後に上記 13 ケースを再実行した。これは probe の不具合であり production Resolver の失敗ではない。

root による再実行で、A の raw JSON と B の raw JSON はそれぞれ保存済み結果と完全一致した。C の盲検監査は [事前チェックリスト](artifacts/blind-audit/CHECKLIST.md) を A/B の結論閲覧前に固定し、[監査結果](artifacts/blind-audit/AUDIT.md) に fixture と主張の限界を記録した。

## Conclusion

Current Canonical 保存は、selected write が slot 置換で無警告に消える組合せを受理する。strict descendant による conflict membership は固定 fixture で機械的に判定できたが、nested selected slots の diagnostic owner、existing `forbiddenOverride` / `conflictingVariants` の error priority、valid な target 自身の write semantics は確定していない。test-only 2 方式はそのまま production-safe ではない。したがって現時点で precedence の正式 Decision を行わず、ADR は **Spike Required** のまま維持する。nested Definition の cycle safety は Document / availability validation にあり、直接 Resolver の再帰展開と混同しない。

## Artifacts

- [Semantic alternatives probe](artifacts/semantic-alternatives/README.md): Current Resolver と test-only 2 案、13 ケース、構造対照、raw JSON、再実行 script。
- [Production validation probe](artifacts/production-validation/README.md): Validator / Canonical 保存と reopen、11 ケース、nested cycle、bytes 前後一致。
- [Independent blind audit](artifacts/blind-audit/AUDIT.md): 結果前に固定した checklist と raw probe / source に基づく監査。
