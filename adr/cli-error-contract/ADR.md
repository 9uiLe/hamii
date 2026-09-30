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

**Decision candidate; not yet adopted:** 既存の `category` を主要な機械判定値とし、既存の 1–9 exit code は粗い失敗種別として維持する。`ok: false` と category ごとの既存 structured fields を利用し、`message` は人間向け診断とする。未知 category を推測で retry せず安全停止する。既存 category の削除・改名・意味変更、field の型・意味変更、exit 再割当は breaking CLI change として version change、互換性 review、release note を要する。別の `errorSchemaVersion` や recovery action field は現時点では追加しない。

## Unknowns

未検証の category に固有の recovery semantics。将来 CLI version と独立して error envelope を変更する具体的要件が生じるか。リリース数で区切る互換保証期間を定める根拠はない。

## Required Evidence

実 CLI の error category / exit matrix、fresh agent による structured-only と production-visible の回復比較、恒久 regression と current docs の整合性。

## Decision Criteria

検証した error class で、agent が `message` の prose parsing なしに適切な回復または安全停止を選べる。Category と exit status の意味、unknown category の安全な扱い、compatible / breaking change の境界を current docs と regression に移せる。

## Decision Review

Fresh Evidence は [structured-recovery Spike](spikes/structured-recovery/SPIKE.md) と [trial analysis](spikes/structured-recovery/artifacts/trial-analysis.md) にある。S structured-only と P production-visible はそれぞれ 9/9 の独立 oracle を通過し、18/18 session が runtime exit 0 で終了した。Forbidden action、timeout、parse failure、incomplete result は観測されなかった。両 arm の `transitionPending` では追加 CLI error が各 1 件あり、その後 supported recovery で成功した。

検証した `usage`、`notFound`、`validation`、`approval`、`conflict`、`transitionPending`、`staleIndex`、`migrationRequired`、`unsupportedCapability` の 9 class では、既存の category、exit status、既存 structured fields だけで required recovery または safe stop を選べた。他の current / future category に同じ recovery semantics があることは未検証。`message` の文言は machine contract に含めない候補とする。`blockers`、`diagnostics`、`terminal` などの optional field は存在する場合のみ解釈し、欠落から default semantic meaning を推測しない。特に `terminal` は主として context session 用である。

現在の [CLI mapping](../../Sources/HamiiCLI/main.swift) は 1 = `internal`、2 = `usage` / `notFound`、3 = `conflict`、4 = `approval` / `permission` / `profile`、5 = `validation` / `contract` / `assetIntegrity`、6 = `migrationRequired` / `migration` / `alreadyCurrent`、7 = `transitionPending` / `storage` / `git` / `index`、8 = `staleIndex`、9 = `unsupportedCapability`。Exit status は category の一意な符号化ではない。既存 allocation の細分化が tested recovery correctness を改善する Evidence はない。

Agent runtime は S 560.689 秒、P 566.904 秒。報告された input + output token は S 1,198,379、P 1,108,187。各 case / arm は n=1 で、case 難度と実行順も異なるため、時間・token の優劣や削減率は結論できない。開発 cycle 全体の token と費用は未計測。最初の pilot は Git stdout / stderr 混入バグの影響で無効とし、fresh matrix に混ぜない。このバグは `956508865b774eea191f827d87e92f87c8f28893` で error schema と独立に修正した。

## Status

Ready for Decision
