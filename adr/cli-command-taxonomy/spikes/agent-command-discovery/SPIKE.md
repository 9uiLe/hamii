# Fresh-agent command discovery

## Related Decision

[CLI semantic command taxonomy](../../ADR.md): bootstrap から代表タスクに必要な command tree / live skill を、推測せず小さい context と少ない往復で発見できるか。

## Hypothesis

**Tentative:** resource / verb / task の一貫した prefix は CURRENT と比べて discovery の往復または誤った grammar の試行を減らせる可能性がある。CURRENT を保持する判断も有効で、taxonomy 変更を目的にしない。

## Questions

- 同じ semantics の下で、必要な command が live skill から発見されるか。
- Task success、未発見 command attempt、usage error、discovery calls、読み込む skill bytes はどう変わるか。
- 変更 / migration の負担を正当化する差があるか。任意の加重 score は作らない。

## Prototype Scope

- [Candidate manifest](artifacts/taxonomy-candidates.json): CURRENT / RESOURCE / VERB / TASK の42 operation prefix、operand grammar、skill text と semantic fact IDs を固定する。
- [Task suite](artifacts/task-suite.json): stable fixture IDs、5 task の意味と oracle、順序、失敗判定、runtime と計測範囲。
- [Initial prompt](artifacts/agent-prompt.txt): 全8 session へ byte-identical に提供。候補名を含めず、共通の bootstrap invocation だけを最初の command instruction とする。
- Test-only proxy は `candidate argv → production argv → 同じ Release hamii → stdout/stderr/exit passthrough`。Skill discovery だけは固定 candidate catalog を返す。未知 prefix は proxy usage error として記録する。
- ID discovery、inspect/context の隠れた呼出し、`--state` 挿入、retry、business rule、validation の実装は proxy に持たせない。
- 9個の semantic skill group 境界は CURRENT と同じ。候補に合わせて group 名と command prefix を変える。この Spike は任意の skill 再分割を比較しない。

## Out of Scope

Production command rename、error schema / exit allocation、GUI naming、MCP、prompt 最適化、agent autonomy、context session transport、CI reshard、検査省略。Index / ClientPrecondition / Authoring semantics は同じ production path を使う。

## Measurements

### Fixed protocol

1. Plan commit / push の exact-SHA Verify success 後にだけ fresh-agent trial を開始する。
2. 同じ Release binary、初期 Canonical fixture、model/config/tool access を全試行に使う。Binary / prompt / manifests / fixture の identity、toolchain、OS、agent CLI version と effective model が取得可能なら記録する。
3. 各 trial は repository 外の disposable workspace と新規 `codex exec` session。resume / fork / shared conversation は禁止。Task prompt、`./hamii`、`project/` だけを task context とし、source / README / ADR / proxy / Canonical の直接 inspection、web、raw Git、直接編集を禁止する。
4. Workspace sandbox と実際の tool invocation / command log を監査する。これは experiment の情報提供 / audit boundary で、host 上の任意ファイルを不可視にする security guarantee ではない。Forbidden access は invalid trial として残す。
5. 固定順序: CURRENT-1、RESOURCE-1、VERB-1、TASK-1、TASK-2、VERB-2、RESOURCE-2、CURRENT-2。各 session の timeout / 失敗 / 中断も記録し、成功例だけを残さない。
6. 5 task を順に実施。Task marker は計測だけに使い、state / command の補完をしない。独立 oracle が実 Document と structured CLI outputs を検査し、自己申告を success にしない。

Runtime は既存 user configuration の model `gpt-6.1-sol` / reasoning `high` を全 session へ固定する。公式資料の「`stdout` becomes a JSON Lines (JSONL) stream」と [usage example](https://learn.chatgpt.com/docs/non-interactive-mode) に従い、`turn.completed.usage` を取得できた場合だけ session usage とする。[Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference) と installed CLI 0.159.1 の help に基づき workspace-write、never approval、web disabled、project instruction bytes 0 を固定する。製品の AI interface は hamii CLI のまま。

### Fairness and discovery definition

全 catalog の semantic fact union は同じで、非 grammar の説明は同じ原文を保持する。Skill 名の参照と command prefix だけを置換する。全 catalog UTF-8 bytes の最大 / 最小 ≤ 1.10 を trial 前に検査する。Plan 時点で CURRENT 6,065 / RESOURCE 6,099 / VERB 6,172 / TASK 6,224 bytes、比1.0262。これは token SLA ではない。

`undiscoveredCommandAttempt` は、attempt 前の bootstrap / skills list / skills get がその operation の exact prefix / grammar をまだ提示していない場合。動的 ID の値は grammar disclosure 条件に含めない。Error response で得た usage はこの positive discovery 条件に加えない。CURRENT は実 live skill の文字列を保持し、他候補だけ command prefix と対応する skill 名を置換する。

各 task / trial: oracle success、discovery calls、skills loaded / bytes、command attempts / successful commands、usage / other structured errors、undiscovered attempts、CLI response bytes、wall seconds。Suite 合計と2試行の値 / median / min / max を別々に表示する。n=2 から p95、統計的優位性、実測 throughput を主張しない。Wall time は provider variance を含み、それだけで winner を決めない。

### Tokens and costs

Authoritative per-session input / output / total token telemetry が取得できる場合だけ記録する。Cached / reasoning の包含関係を確認し、重複加算しない。取得不能は `unmeasured`。Agent subset の usage が取れても、operator / 調査 / 実装 / 統合 / CI 確認を含む全開発 cycle の token は別であり、完全な telemetry がなければ未計測。Bytes / chars / calls を token 削減率へ換算しない。費用と時間も別評価する。

### Evidence retained

Structured events と CLI structured response、oracle、runtime provenance、失敗・invalid・timeout の記録だけを commit する。LLM prose / private reasoning / full conversation は commit しない。ログは各 trial 実行中に保存し、完了だけを一括保存しない。

## Success Criteria

- 4 grammar / 同じ fact union / payload fairness / task / prompt / 順序が試行前の Git history にある。
- 8 fresh session の全成功・失敗・中断を保持し、同じ model/config/tool access を確認する。
- Independent oracle と structured logs が各 task の判断可能な結果を示す。
- Production Sources は変わらず、state / validation / Scope の shortcut がない。
- Full local gate と exact pushed-SHA CI が成功する。

Spike success は全候補 task success を意味しない。候補 failure も evidence とする。

## Failure Criteria

候補ごとの semantic fact 差、公平性超過、同じ conversation の再利用、未記録の失敗、hidden ID/state/retry、trial 後の grammar/task/prompt/順序変更は比較不成立。Direct Canonical edit / source-doc-proxy inspection / validation bypass は invalid trial。Production が危険な mutation を拒否したこと自体は安全性 failure ではなく、agent error metric とする。明示的に禁止された PrivateBadge を instantiate しようとした場合は、拒否されても T2 の task adherence は failure とする。Oracle failure は task failure。

## Result

Not run. Live CURRENT catalog の採取と4候補の静的 fairness 確認は plan preparation であり、fresh-agent evidence ではない。Proxy / fixture / oracle は Evidence commit に追加する。CURRENT の取得元は `1bf458a` の production source、application version 0.1.0。

Plan `c6b0298` 後、agent trial 前の fixture preparation で root の spacingTokenID が static generator の非対応 semantics として拒否された。Token は T3 用に保持し、fixture root から参照を外した。T1 で新規 Screen に token を割り当てる authoring task は変えない。初回 bootstrap invocation と task metric labels も試行前に明示化した。[Preparation record](artifacts/pre-trial-preparation.json) に失敗 / 修正 / prompt identity を保持する。Agent trial はまだ0件で、candidate grammar と skill text は変更していない。

## Conclusion

未決定。ADR は Spike Required。Evidence commit の full gate / push / exact-SHA Verify success 後に STOP / report し、Decision Review を行う。Prototype の結果を自動的に production rename にしない。

## Artifacts

- [Candidate grammar and live skills](artifacts/taxonomy-candidates.json)
- [Task suite and oracle contract](artifacts/task-suite.json)
- [Byte-identical agent prompt](artifacts/agent-prompt.txt)
- [Pre-trial preparation failure and correction](artifacts/pre-trial-preparation.json)
