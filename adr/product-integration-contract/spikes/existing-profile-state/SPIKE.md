# Spike: Existing profile state and edit route

## Related Decision

[Product Integration Contract](../../ADR.md) の contract 粒度を判断するため、既存 reducer/store architecture に対する mapping を比較する。

## Hypothesis

Screen 単位の semantic contract と固定した repository convention だけでも、既存 profile state と既存 edit route を source evidence から発見し、並列の business state / route を作らず統合できる可能性がある。Component / dependency graph の構造が必要かは未確定。

## Questions

- 3表現で同一の I01–I11 を既存 profile state / route に結び付けられるか。
- 現行 `IntegrationContract` に独立した States / dependency structure field がないことは、screen 表現の mapping に支障となるか。Shared fixture や prompt による補足を分けて記録する。
- Existing reducer test と source audit で意味と既存 action/path の再利用を確認できるか。

## Prototype Scope

固定 SHA の実 Repository 1件で component / screen / graph の3表現を比較する。各試行は独立 checkout と fresh agent context を用い、実行順を事前に固定する。Production `HamiiIntegration` / CLI は変更しない。

## Out of Scope

新しい runtime/UI test、独立 Human review、Production adapter、任意 Repository の一般化、外部 Repository への push。

## Measurements

### Predeclared protocol — before attempts

- Target: [Team MINO iOS](https://github.com/mash-up-kr/Team-MINO-iOS) @ `dca2202f4be21869190d19bbcf223eb8646a2acd`; [Apache-2.0 license](https://github.com/mash-up-kr/Team-MINO-iOS/blob/dca2202f4be21869190d19bbcf223eb8646a2acd/LICENSE). `FeatureProfile` は既存 MVI `Store` / reducer、`Profile` model、edit action、coordinator route、対応するテストを持つ。固定 SHA の `FeatureProfile` scheme を iOS 27 Simulator で test し、**30 tests / 3 suites passed**。外部 checkout、DerivedData、raw logs は `/tmp/hamii-integration-spike/` に置く。
- Baseline command: `xcodebuild test -scheme FeatureProfile -destination 'platform=iOS Simulator,id=10849834-229F-4AB1-A1B3-88BBEB25B5CF' -derivedDataPath <outside-hamii> CODE_SIGNING_ALLOWED=NO` from `Packages/FeatureProfile`. 同じ suite を各 final patch に再実行し、profile edit reducer / coordinator tests が含まれることを確認する。
- Previous candidate [Memorizing](https://github.com/JongHyunLee84/Memorizing) @ `fdc6795488a1bbbcacb2d4c13deb0f6444f8f3ba` は existing profile + edit test を持つが、unmodified baseline test は解決された TCA 1.26.2 で `PersistenceReaderKey` が見つからず失敗した。契約方式の失敗として数えない。
- Same semantic fixture I01–I11, same pinned target and source convention extract, same allowed files, same Xcode / simulator / test command, same model/tool mode. I01 `displayName` は既存 user name、I02 `secondaryText` は既存 `Profile` model の登録日から得る visible secondary text。新しい fixture-owned profile/business state を作らない。I04/I11 は source に実在する edit action / destination を用いる。Repository profile は destination mapping を与えない。Source から根拠を見つけられなければ明示 unresolved とし、想像で route を作った場合は failure。
- Screen 表現の production 類似フィールドには States / dependency graph を追加しない。全試行に同じ canonical semantic fixture を渡すので、screen 試行がそれで補われた場合は screen contract 単体の成功と主張しない。後付け `stateNote` を追加しない。
- Order: `screen → component → graph`。2026-10-01 に Python `secrets.SystemRandom().shuffle(["component", "screen", "graph"])` の結果を試行前に記録した。各 attempt は前の prompt / diff / review を受け取らない fresh agent context で、固定 prompt と独立 checkout から開始する。
- Review interval: initial patch available → all I01–I11 classified, correction candidates recorded. Record exact source path/line, patch files and +/- lines, build/test exit status and test counts, AI semantic / architecture / cosmetic correction candidates, elapsed review time. Independent Human correction is unmeasured. Save failed and corrected attempts too.

## Success Criteria

3 attempts completed; I01/I02 map to existing profile/user model with no parallel business state; I04/I11 reuse existing reducer action/path/destination; all I01–I11 are mapped with exact source evidence or explicitly unresolved; silent guess and silent loss are both 0; each final patch passes baseline-equivalent 30-test gate; screen-specific supplemental context is disclosed.

## Failure Criteria

An attempt invents parallel business state or route, loses an intent silently, claims ungrounded mapping, fails the fixed test gate after correction, or contaminates a later agent with an earlier attempt's result. A baseline failure is target selection failure, not a contract-shape failure.

## Result

Pending the three attempts.

## Conclusion

Pending evidence. The ADR remains `Spike Required` until this comparison is complete and its limitations are assessed.

## Artifacts

Fixed fixture, three contract representations, common repository convention, prompts, diffs and per-attempt audit belong in [artifacts/](artifacts/). Large checkout / build output remains outside this Repository.
