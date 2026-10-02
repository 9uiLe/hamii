# Spike: Slot conflict と既存 error の優先順位

## Related Decision

[Component Variant と Instance の解決](../../ADR.md)。[slot-write-conflict-boundary Spike](../slot-write-conflict-boundary/SPIKE.md) は、slot が先行書込みを消しても Canonical Data へ保存できる一方、素朴な test-only 候補は既存 error を隠すことを確認した。

## Hypothesis

新しい slot conflict を、slot 以前に適用されて無警告で消える **selected Variant / instance propertyValues** の write だけに限定すれば、既存の selection / API validity と Variant 同一 path conflict を優先し、allowed override の後段 `unknownPath` を維持できる。複数 selected slots が同じ path を消す場合、恣意的な単一 owner を選ばず該当 slot 名の安定した集合を示せる。

## Questions

既存の `forbiddenOverride`、unknown variant / property / slot、`conflictingVariants` を新 conflict より先に保持できるか。public allowed override の現行 `unknownPath` を変えずに済むか。nested selected slots の全 conflict owner を tree ancestry から順序独立に列挙できるか。現行 Application Service に Component Instance の slot / variant / property を編集する mutation intent があるか。

## Prototype Scope

test-only priority evaluator 1案を現行 Resolver と固定 fixture で比較する。別 fixture で有効な Current Document の nested selected slots を DocumentValidator、CanonicalRepository、利用可能な ProjectService mutation 境界まで確認する。test-only preflight による拒否と production での実装を厳密に区別する。独立監査は A/B の raw probe と result を確認する。

## Out of Scope

production `Sources/` / `Tests/HamiiTests/`、production error enum、一般的な slot UI、nested Definition の再帰 materialization、performance / cache の確定。

## Measurements

source commit、環境、fixture、再実行 command、現行 Resolver / test-only evaluator の typed result、nested slot 名の集合と順序対照、DocumentValidator diagnostics、Canonical commit / reopen、ProjectService の実際の mutation 可否、拒否前後の Canonical JSON bytes / revision を記録する。

## Success Criteria

invalid-input error と selected Variant 同一 path conflict が新 slot conflict より優先する。selected Variant / property の silent loss のみ typed conflict になり、allowed override の現行後段 semantics を保つ。nested slot の全 owner 集合が slot 名 / Dictionary insertion 順を変えても同じ。production と test-only 境界を過大主張しない。

## Failure Criteria

既存 error を隠す、未選択 Variant や unrelated path を誤拒否する、allowed override の error semantics を理由なく変更する、nested slot の owner を恣意的に1件へ縮約する、または test-only gate を production ProjectService の実装済み rule と表現する。

## Result

source `c43ea3179559d55049db4e98db4cf013e81b0588`、macOS 27 arm64 / Swift 6.4。test-only priority evaluator は固定18ケースの期待値と一致した。selected Variant / instance propertyValues が selected slot の元 subtree の **strict descendant** に書く場合、消去する selected slot 名の安定ソート済み全件を返す。未選択 Variant、slot 対象外 write、slot 未選択、public `allowedOverrides` の単独対照では新 conflict を返さなかった。public override が slot で消えた path に書く場合は現行の `unknownPath` が残る。単独不正の `forbiddenOverride`、unknown variant / property / slot、selected Variant 同一 path の `conflictingVariants` もそれぞれ観測した。ただし18/18は **candidate 自身の期待値** との一致であり、現行 Resolver との全面一致ではない。[priority raw result](artifacts/priority-evaluator/result.json) と[再実行手順](artifacts/priority-evaluator/README.md)を参照。

反例は2つある。selected nested slots が `inner`→`outer` の順なら現行 Resolver は先行書込みを黙って消す一方、`aOuter`→`zInner` の順なら outer が inner target を先に消して現行 Resolver は `unknownSlot:zInner` を返す。test-only 先行 conflict は後者を `slotWriteConflict` に置き換える。また `conflictingVariants` と forbidden override が同時にある場合、現行は `conflictingVariants`、validity-first 候補は `forbiddenOverride` を返す。既存 error の全面的な優先順位保存は **失敗** した。

Application 境界の固定5ケースでは、valid Current Document の inner→outer selected write が `DocumentValidator` 診断0件、Canonical commit/reopen 受理となり、失われた old Text は復元されなかった。outer→inner は `component.resolution` で Canonical commit が拒否され、試行前後の Canonical JSON path→bytes は同一だった。両順序の test-only detector は同じ old descendant に対して2 slot 名を列挙した。test-only pre-service gate は `ProjectService.mutate` を **呼ばない** 分岐なので、その分岐で bytes / revision / `ClientPrecondition` が変わらない事実は production 拒否や race safety の証拠ではない。実 Service 呼出しは無関係な `createPage` だけで、現行 `AuthoringIntent` に slot / Variant / property を直接編集する intent はない。[Application raw result](artifacts/application-boundary/result.json) と[境界説明](artifacts/application-boundary/README.md)を参照。

[事前固定 checklist](artifacts/blind-audit/CHECKLIST.md) に基づく[独立監査](artifacts/blind-audit/AUDIT.md)も、混合不正と outer-first nested slot で優先順位が変わること、Application gate は未統合であることを確認した。root は A/B probe を再実行し、18ケースと5ケースの raw result がそれぞれ保存済み結果と一致した。これは固定 fixture の correctness evidence であり、性能値・production rule の完成証明ではない。

## Conclusion

silent discard を selected prior write に限定して検出し、全 slot owner を列挙する方向には Evidence がある。ただし nested slot の既存 `unknownSlot` と混合不正時の `conflictingVariants` をどの順位で扱うかは未決定で、今回の validity-first 候補は全面的な優先順位保存条件を満たさなかった。production への採用は決めない。ADR は `Spike Required` を維持し、次の Decision input は overlapping selected slots の扱いと複合不正の診断優先順位を明確にすること。test-only gate を production 実装として扱わない。

## Artifacts

- `artifacts/priority-evaluator/`: error priority と全 slot owner 集合。
- `artifacts/application-boundary/`: Current Canonical / ProjectService と test-only gate の境界。
- `artifacts/blind-audit/`: 結果前に固定する監査条件と独立評価。
