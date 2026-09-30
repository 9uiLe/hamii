# CLI structured error と exit status

## Context

CLI は AI、CI、scripts の唯一の automation interface。現在の error category と exit code は動作している。既存の structured error が automation の判断に十分か、互換性をどう扱うかを判断する。

## Decision to Make

Machine-readable error category、diagnostic envelope、exit status の allocation と versioning rule を決める。

## Constraints

GUI と同じ Application Service を使う。Human output と JSON output を分離する。AI は prose parsing をしない。

## Options

少数の固定 exit code と category、category ごとの exit code、別 schema version を持つ envelope。

## Current Hypothesis

Decision Review 時の仮説は、既存の `category` と粗い exit status を維持することだった。以下の Decision に採用した。

## Unknowns

未検証の category に固有の recovery semantics は推定しない。将来 CLI version と独立して error envelope を変更する要件が発生した時だけ別 schema version の必要性を検討する。リリース数で区切る互換保証期間を定める根拠はない。

## Required Evidence

実 CLI の error category / exit matrix、fresh agent による structured-only と production-visible の回復比較、恒久 regression と current docs の整合性。

## Decision Criteria

検証した error class で、agent が `message` の prose parsing なしに適切な回復または安全停止を選べる。Category と exit status の意味、unknown category の安全な扱い、compatible / breaking change の境界を current docs と regression に移せる。

## Decision Review

Fresh Evidence は [structured-recovery Spike](spikes/structured-recovery/SPIKE.md) と [trial analysis](spikes/structured-recovery/artifacts/trial-analysis.md) にある。S structured-only と P production-visible はそれぞれ 9/9 の独立 oracle を通過し、18/18 session が runtime exit 0 で終了した。Forbidden action、timeout、parse failure、incomplete result は観測されなかった。両 arm の `transitionPending` では追加 CLI error が各 1 件あり、その後 supported recovery で成功した。

検証した `usage`、`notFound`、`validation`、`approval`、`conflict`、`transitionPending`、`staleIndex`、`migrationRequired`、`unsupportedCapability` の 9 class では、既存の category、exit status、既存 structured fields だけで required recovery または safe stop を選べた。他の current / future category に同じ recovery semantics があることは未検証。`message` の文言は machine contract に含めない候補とする。`blockers`、`diagnostics`、`terminal` などの optional field は存在する場合のみ解釈し、欠落から default semantic meaning を推測しない。特に `terminal` は主として context session 用である。

現在の [CLI mapping](../../Sources/HamiiCLI/main.swift) は 1 = `internal`、2 = `usage` / `notFound`、3 = `conflict`、4 = `approval` / `permission` / `profile`、5 = `validation` / `contract` / `assetIntegrity`、6 = `migrationRequired` / `migration` / `alreadyCurrent`、7 = `transitionPending` / `storage` / `git` / `index`、8 = `staleIndex`、9 = `unsupportedCapability`。Exit status は category の一意な符号化ではない。既存 allocation の細分化が tested recovery correctness を改善する Evidence はない。

Agent runtime は S 560.689 秒、P 566.904 秒。報告された input + output token は S 1,198,379、P 1,108,187。各 case / arm は n=1 で、case 難度と実行順も異なるため、時間・token の優劣や削減率は結論できない。開発 cycle 全体の token と費用は未計測。最初の pilot は Git stdout / stderr 混入バグの影響で無効とし、fresh matrix に混ぜない。このバグは `956508865b774eea191f827d87e92f87c8f28893` で error schema と独立に修正した。

## Decision

`--json` の失敗は `ok: false`、既存の `category`、非ゼロ process exit、存在する場合の category-specific structured fields、任意の人間向け `message` で表す。`category` は machine error identity、exit status は粗い失敗種別であり、exit status だけで retry 方法を決めない。Automation は `message` の prose や文言を parse して回復判断をしない。任意 field が欠けていることから、特定の意味や false 値を推測しない。

既存 category の exit allocation は Decision Review の 1–9 mapping を維持する。未知 category を受け取った consumer は自動 mutation / retry をせず、安全停止して確認を求める。新しい意味に対する category と optional structured field の追加は compatible。既存 category の削除・改名・意味変更、既存 field の型・意味変更、既存 category の exit 再割当、安全な解釈に必須の field の追加は breaking CLI contract とし、CLI version change、明示的な compatibility review、release note を要する。既存 machine contract は breaking-version decision まで維持する。根拠のない N release 保証はしない。

検証した 9 class の回復または安全停止には既存 envelope で十分だったため、`retryAction`、`recoveryCommand`、`humanRequired`、`reasonCode`、別の `errorSchemaVersion` は追加しない。具体的な回復手順は installed live skills と category-specific workflow で案内する。今回の実験は他 category の retry semantics や S/P の時間・token 優劣を証明しない。

Current documentation と実 CLI を用いた恒久 regression の実装・検証は `b880e3519cc299037d2aa99608896b7c81e518f6` で完了した。

## Closure Review

Decision と Evidence は別々の Git commits に残る。最初の plan は `f4c340380cb461a878be018a2c2f23047f12b136`。無効な pilot で判明した Git subprocess channel bug は `956508865b774eea191f827d87e92f87c8f28893` で修正し、[Verify 36742941234](https://github.com/9uiLe/hamii/actions/runs/36742941234) は成功した。改訂 plan は `c9a50cdbb0e7f0602a41b6e1a6ce9a6e6e6d6941`、[Verify 36747742840](https://github.com/9uiLe/hamii/actions/runs/36747742840) 成功。Fresh 18-session Evidence は `44d0141e84b90a1bedded56370c9c6d934fc593e`、[Verify 36753271671](https://github.com/9uiLe/hamii/actions/runs/36753271671) 成功。Decision Review は `e394fafea919026fd41dc5f89dcd840471733875`、[Verify 36756282522](https://github.com/9uiLe/hamii/actions/runs/36756282522) 成功。Formal Decision は `1383b470d22b8a630727f938eb82f0edbecbb97a`、[Verify 36756423114](https://github.com/9uiLe/hamii/actions/runs/36756423114) 成功。

Implementation `b880e3519cc299037d2aa99608896b7c81e518f6` は current schema を意図的に維持し、[CLI error contract](../../docs/cli-error-contract.md)、[Current Architecture](../../docs/final-architecture.md)、実 CLI の恒久 [error smoke](../../scripts/smoke-cli-errors.py) を追加した。[Verify 36757608426](https://github.com/9uiLe/hamii/actions/runs/36757608426) は成功。ローカル full gate は 14/14 checks、296 Swift tests、61 skips、failure 0、373.358 秒。Error smoke は `usage/2`、`notFound/2`、`validation/5`、`approval/4`、`conflict/3`、`transitionPending/7`、`staleIndex/8`、`migrationRequired/6`、`unsupportedCapability/9` と既存 `permission/4` を検査し、message の exact wording を固定しない。AI agent trial は CI に常設していない。

Decision、Spike、implementation、validation は完了し、current docs と regression が契約を独立して表す。無効 pilot は fresh matrix から除外した。未検証 category の retry semantics、時間・token 削減率、将来の別 error schema version は決定として主張しない。この Decision Boundary に残る必須 work はない。ADR の履歴をこの commit に保存した後、別 commit で working queue から削除する。

## Status

Implementation Required
