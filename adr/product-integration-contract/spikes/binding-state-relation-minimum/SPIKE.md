# Spike: Minimum binding-to-state relation

## Related Decision

[Product Integration Contract](../../ADR.md) の contract 粒度のうち、I01/I02 の状態依存意味を安全に伝えるための最小構造を検証する。

## Hypothesis

この Team MINO profile summary の P0–P4 では、semantic source・可視条件・nil behavior・transform を output ごとに記す typed relation で十分であり、full dependency graph は必要条件でない可能性がある。複数 source の複雑な導出への一般化はしない。

## Questions

- Typed binding relation R と annotated dependency graph G は P0–P4 × I01/I02 の10セルを一意に導けるか。
- Cached refresh の P1/P2 を P0 と区別できるか。
- Repository mapping が欠けたとき、両候補とも Needs Resolution に落ちるか。
- Graph 固有の node/edge が、このケースの state/output 意味を導くのに必要か。
- Update trigger を独立 field として必要とする evidence があるか。

## Prototype Scope

固定 Team MINO iOS `dca2202f4be21869190d19bbcf223eb8646a2acd` に対する knowledge Spike。既存 screen/component/graph 外枠は比較しない。Spike-only の R/G JSON、同じ oracle と proposed Repository mapping、決定的 evaluator を作る。R と G に対し生成に参加していない fresh agent の source audit を1件ずつ行う。両 agent には oracle の expected output を渡さない。

## Out of Scope

Production `IntegrationContract` / CLI / Core IR、target source patch、Xcode runtime validation、I03 avatar visual resolution、最終 Product copy / locale policy、全 UI domain への一般化、方式の正式 Decision。

## Measurements

### Fixed semantic oracle — evaluator only

| Case | Source state | Expected I01 | Expected I02 |
| --- | --- | --- | --- |
| P0 | First load, renderable profile なし、loading | hidden | hidden |
| P1 | Last-known profile あり、refresh loading | cached displayName | cached membership date |
| P2 | Refresh failure、last-known profile あり | cached displayName | cached membership date |
| P3 | Loaded profile、`createdAt == nil` | displayName | `가입일 정보 없음` |
| P4 | Loaded profile、`createdAt != nil` | displayName | date-derived Korean membership text |

P1/P2 の cached date と P4 の date は evaluator で具体値を固定する。Date transform は Spike 専用の deterministic UTC/Gregorian `yyyy년 M월 d일 가입` とし、最終 Product copy とは扱わない。Oracle output は candidate JSON や independent audit packet に入れない。Candidate が意味的 source（例 `profile.displayName`, `profile.createdAt`, `profile.renderable`）を参照し、Product の `Profile.nickname` 等への mapping は別 artifact にする。

R/G の各10セルを `sufficient / ambiguous / unresolved` と出力値で評価する。Missing `profile.renderable` mapping の negative case、誤った nil fallback を oracle が検出するかも検証する。比較は semantic primitive、state rule 重複、10セル完全性、fail-closed、Product architecture leakage とし、JSON byte 数は参考値だけにする。Raw evaluator result、source audit と所要時間を保存する。

## Success Criteria

R/G の10セルが隠れた prose なしに期待値と一致するか明示できる。P0 と P1 が別の出力になり、P1/P2 は last-known values を保つ。Mapping 欠落時に Needs Resolution へ落ちる。Product-specific source path が candidate contract に漏れず、source audit が安全な patch plan と追加情報要求を分けて記録する。

## Failure Criteria

候補が oracle の prose に依存する、P0/P1 を混同する、source 名から Repository mapping を推測する、mapping 欠落でも値を返す、I02 の nil/date rule を黙って補う、特定候補を byte 数だけで採用する。

## Result

2026-10-01、[R/G、oracle、proposed Repository mapping と evaluator](artifacts/README.md) を固定して比較した。両候補は同じ semantic sources `profile.renderable` / `profile.displayName` / `profile.createdAt` を使い、Team MINO の `Profile.nickname` 等の Product source path は候補 JSON へ入れていない。変換 registry の `membershipDate-ko-utc-v1` は Spike 専用であり最終 Product copy ではない。

| Evaluator property | R: typed relation | G: annotated graph |
| --- | --- | --- |
| P0–P4 × I01/I02 | 10/10 `sufficient`、oracle visibility/value と一致 | 10/10 `sufficient`、同じ値 |
| P0 vs P1/P2 | P0 hidden、P1/P2 は cached source を表示 | 同じ |
| P3 nil date | `가입일 정보 없음` | 同じ |
| P4 nonnil date | UTC/Gregorian transform | 同じ |
| `profile.renderable` mapping 欠落 | 10/10 `Needs Resolution` | 10/10 `Needs Resolution` |
| 同 mapping が空 object | 10/10 `Needs Resolution` | 10/10 `Needs Resolution` |
| 誤った nil fallback | oracle が P3/I02 不一致を検出 | 同じ |
| Semantic primitive classes after normalization | 6; missing-mapping guard は共通 evaluator policy | 6; 同じ共通 policy |
| 重複する visibility predicate | 1 | 1 |
| 構造 | 2 relation | 5 node / 4 annotated edge |
| JSON bytes（参考） | 685 | 902 |

`profile.renderable` が false の P0 と true の P1/P2 を分け、P1/P2 は同じ last-known source values を保持する。R と G の正規化した依存元はともに I01=`renderable+displayName`、I02=`renderable+createdAt`。Graph の node/edge はこのケースで R が表せない追加の state/output 意味を提供しなかった。独立した `updateTrigger` field を設けなくても**依存元の識別**は可能だが、runtime での更新通知・順序・atomic snapshot はテストしていない。

初回の [独立 evaluator 監査](artifacts/audits/evaluator.txt) は、P3 複製で P4 欠落を見逃す coverage check と空 mapping 受理を指摘した。修正後の [follow-up](artifacts/audits/evaluator-followup.txt) では、P0–P4 固有 ID、期待 output keys、source/mapping fields・types を検査し、重複 case・空 mapping・Product 型を拒否した。出力順も固定した。最後に候補固有の6 primitive と共通 missing-mapping policy を結果上で分離した。最終2回の実行と保存済み `evaluation.json` は SHA-256 `45f4849a7c59e072d5917f59c4f5ca4d76956eae8e516a97e3bc85bc36815dee` でバイト一致した。Candidate JSON の Product symbol scan は現在の2文書に対する bounded check であり、任意 schema の一般的な architecture test ではない。

Expected outputs を見ない fresh context での [R audit](artifacts/audits/R.txt)（100秒）と [G audit](artifacts/audits/G.txt)（102秒）は、いずれも同じ P0–P4 の表示規則を candidate から導いた。両 audit は proposed mapping と現行 Product source を分離した。Team MINO の `ProfileMainState` は nickname を保持するが、明示的な profile existence と `createdAt` は保持していない。Cached profile を持つ coordinator と Domain `Profile.createdAt` は source 上にあるが、mapping の production 実装は必要である。DTO は network `createdAt` を nonoptional とするため、Domain の nil date は現行 API path では通常発生せず、test/domain case として残る。I01 の semantic source は optional で、renderable=true かつ nil name は `Needs Resolution` とした。現行 Product `Profile.nickname` は nonoptional なので今回10セルでは発生しない。

**Interpretation:** この Team MINO の synthetic 10セルでは、R の typed relation で状態依存意味を表現でき、full dependency graph は必要条件ではなかった。ただし R と G とも提案 mapping の上で評価した knowledge prototype であり、Product へ安全な source patch が一意に決まった証拠ではない。各 auditor は `Profile?` 保持と別 presence flag など複数の実装形を挙げた。Cache の保持、更新伝播、日付表示、UI の runtime correctness は未検証である。Byte 数や1件ずつの audit 時間を方式採否の根拠にしない。I03 の avatar conflict は [独立 review](../independent-diff-review/SPIKE.md) の shape-independent `Needs Resolution` evidence として維持し、ここでは visual resolution をしない。

## Conclusion

固定した P0–P4 / I01–I02 の範囲では、typed binding relation R は graph G と同じ10セルを完全に表し、mapping 欠落時に fail closed した。Graph の追加の topology は、この state/output 意味を導くための必須情報ではなかった。この限定結論は full UI domain や production runtime へ一般化しない。Contract の粒度を選ぶための主要な比較 Evidence が揃ったため、Product Integration Contract ADR は `Ready for Decision` とし、方式の正式採用は別 commit の判断に残す。

## Artifacts

[artifacts/README.md](artifacts/README.md) から候補、oracle、再現コマンド、機械結果、独立 audit とその修正履歴へ辿れる。
