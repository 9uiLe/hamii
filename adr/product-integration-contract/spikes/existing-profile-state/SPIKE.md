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

2026-10-01、事前に固定した `screen → component → graph` の順で3つの独立 agent context と独立 checkout を使用した。各 agent には担当 [prompt](artifacts/attempts/) のみを渡し、他方式の diff / review を渡さなかった。モデル・file/terminal tool 条件は同じ親設定を継承した。3試行とも source は `dca2202f4be21869190d19bbcf223eb8646a2acd`、変更は許可した `FeatureProfile/Main` の2ファイルのみ。外部 target へ commit / push はしていない。

| Shape | Existing state and route | I03 system avatar | Final existing tests | Initial gate / correction | AI self-review / applied semantic·architecture·cosmetic | Final patch |
| --- | --- | --- | --- | --- | --- | --- |
| [screen](artifacts/attempts/screen/RESULT.md) | `Profile.nickname` / `Profile.createdAt` と既存 edit route に対応 | SF Symbol を既存 avatar art の上へ常時表示。source 上は指定画像を満たすが、視覚品質は未確認 | 30/30, 3 suites, exit 0 | 一時 State 経由の日付算出を修正 | 76 s / 1·0·0 | 2 files, +28/−1 |
| [component](artifacts/attempts/component/RESULT.md) | 同じ既存 model / route に対応 | 色未選択時の fallback のみ。色選択時は既存 art のため I03 は**部分的・未達** | 30/30, 3 suites, exit 0 | 初回 build exit 65 (`some View` の `return` 不足)、修正後成功 | 92 s / 1·0·1, plus 1 compile fix | 2 files, +23/−4 |
| [graph](artifacts/attempts/graph/RESULT.md) | 同じ既存 model / route に対応 | 既存 art を保持し SF Symbol を使わないため I03 は**未達** | 30/30, 3 suites, exit 0 | 初回 Xcode test は成功したが zsh wrapper が read-only `status` 代入で exit 1。wrapper 修正後 exit 0 | 110 s / 0·0·1, plus 1 wrapper fix | 2 files, +23/−3 |

**Confirmed for the tested Repository:** I01/I02 は3方式とも実 `Profile` model 由来で、並列の business/profile fixture state は0件。I04/I11 は3方式とも既存 reducer action → navigation effect → coordinator route → edit-mode destination を source と既存 edit tests で追跡した。新しい route / Bool / alert は0件。各 final patch は30件の同じ既存 test gate を通り、明示されない route の創作と silent loss は0件だった。I03 の契約不一致2件を「成功」に含めない。

**Contract-shape interpretation:** screen 表現に独立した States / dependency field はない。I08 normal state と I11 destination discovery の意味は全試行に渡した共通 fixture から補われているため、この結果で「screen contract 単体で十分」とは言えない。component / graph も I02 の日付意味・nil fallback は共通 fixture と target source へ依存した。既存 state / route の発見は3方式で成立したが、構造差の優位性は1 target × 各1試行では確認できない。avatar の不一致は Product の既存 asset behavior と固定 fixture の system image 値の衝突であり、state/route mapping の失敗と分けて扱う。

**Evidence integrity:** 3つの `final.patch.gz` を展開した内容は独立 target checkout の `git diff --binary` とバイト一致し、未変更の pinned checkout に対する `git apply --check` が成功した。`git diff --check` も各 checkout で成功した。外部 source の既存空白を hamii 自身の diff whitespace 判定から分離するため、patch は内容を変えず gzip で保存した。最初の失敗、修正、再実行を各 [RESULT.md](artifacts/attempts/) に残した。full Xcode logs / DerivedData は Repository 外の `/tmp/hamii-integration-spike/` に置き、Git には小さい patch と判定要約のみを保存した。展開後の最終 patch SHA-256 は screen `8fa5eeb65aeec216f642fcb592a0c621b59841944e1d1e32c637f9752998dff7`、component `576d5c465d7f07e581b5da7e7f2032cfe1b88d70b8fa0a2f6ae3a41eb3c4ee53`、graph `22af1786da5a3c7200a8a6857c020224bf46f54111f38aa09aa2ae51cd770dd6`。

**Limits:** source audit と既存 tests は、新しい日付表示の非 nil runtime behavior、avatar の見た目・accessibility、Human correction を検証しない。screen の overlay は実画面で確認していない。各方式1試行の review 時間・行数は因果的な方式比較や Product 性能値ではない。Target の `FeatureProfile` package gate は通ったが app 全体の end-to-end gate ではない。Spike patch は production adapter ではない。

## Conclusion

既存 profile state と edit route の再利用は3方式で実証した。指定 system asset は2方式で未達であり、screen は共通 fixture の補足が必要だった。どの contract 粒度を採用すべきかは、この1 target の結果だけでは決めない。次の Evidence は独立 review または新しい表示・イベントの runtime validation の一方へ絞る。ADR は `Spike Required` のまま維持する。

## Artifacts

Fixed fixture、3 contract 表現、共通 repository convention、prompts、initial/final patch、方式別 source audit は [artifacts/](artifacts/) にある。大きな checkout / build output は Repository 外にある。
