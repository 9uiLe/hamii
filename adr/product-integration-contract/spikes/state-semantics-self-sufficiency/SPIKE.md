# Spike: State semantics self-sufficiency

## Related Decision

[Product Integration Contract](../../ADR.md) の component / screen / graph 粒度のうち、状態差を shared fixture なしで安全に伝えられる構造を判断する。

## Hypothesis

現行 screen 相当の flat `IntegrationContract` は state semantics を保持する専用 field がないため、profile 未取得と取得済み日付 nil の差を単体では表せない可能性がある。component の state list または graph edges が十分かは、3状態を固定して検証する。

## Questions

- 各 contract 単体から S0/S1/S2 を区別し、I01/I02 の表示を一意に導けるか。
- target source に既存の状態が存在することと、hamii contract が要求する state behavior を区別できるか。
- 情報不足の場合に最小の追加情報は何か。state list、binding→state relation、dependency graph の必要性は異なるか。
- contract にない意味を推測せず patch plan を記述できるか。

## Prototype Scope

Team MINO iOS `dca2202f4be21869190d19bbcf223eb8646a2acd` の clean source と、既存 [3 contract expressions](../existing-profile-state/artifacts/attempts/) を用いる。新しい agent context 3つに各 expression 1件を配り、**共通 semantic fixture の全文を渡さない**。各 agent は自分の contract、target source/convention と質問だけを見る。実装は行わない。Evaluator は3状態の正解と agent の contract-only 解釈を後から照合する。

Canonical semantic requirement for evaluation（agent packet には入れない）:

| State | Profile observation | I01 displayName | I02 secondaryText |
| --- | --- | --- | --- |
| S0 | Profile unavailable / loading | まだ表示対象でない | まだ表示対象でない |
| S1 | Profile loaded, `createdAt == nil` | 既存 `Profile.nickname` を表示 | `가입일 정보 없음` を表示 |
| S2 | Profile loaded, `createdAt != nil` | 既存 `Profile.nickname` を表示 | `Profile.createdAt` 由来の Korean membership date を表示 |

`가입일 정보 없음` は固定済み [semantic fixture](../existing-profile-state/artifacts/profile-header-fixture.json) の値を使う。Agent packet では state-specific 表示を教えない。source から発見した Product の既存挙動を hamii contract の要求とみなさない。

## Out of Scope

新しい integration patch、production API / CLI 変更、I03 avatar visual resolution、runtime UI test、Xcode gate、方式の正式採用。

## Measurements

3 shape × 3 state の9セルを `sufficient / insufficient / repository-discoverable / ambiguous` で分類し、contract の exact field と target source location、contract semantics と source discovery の境界、silent guess の有無を記録する。各 agent は S0/S1/S2 を scenario として受け取るが、各 scenario の**期待表示**は受け取らない。Agent は source-level implementation plan を修正・実行せず、必要な情報だけ列挙する。Reviewer context、packet content、開始/終了 UTC、結果を残す。

## Success Criteria

9セルすべてに分類と根拠があり、S0 と S1 を混同しない。Shared fixture supplementation は0。各不足について最小追加情報を具体化し、repository discovery と contract semantics を区別する。Silent guess なしで実装できない場合は `Needs Resolution` と記録する。

## Failure Criteria

Agent に fixture-only meaning を渡す、source の既存 loading state を contract の要求とみなす、test-only `states` / `stateNote` を flat screen contract に追加して十分とする、欠落を黙って補う、9セルを埋めずに方式を決める。

## Result

2026-10-01、[固定 packet と contract SHA-256](artifacts/README.md) で、生成試行に参加していない3つの fresh agent context が screen / component / graph を独立に調べた。各 agent は担当 contract と pinned Team MINO source/convention だけを見て、shared fixture・以前の patch/RESULT・他の probe を受け取らなかった。各結果は source location、contract と Repository の区別、UTC 所要時間を含む：[screen](artifacts/results/screen.md) 89秒、[component](artifacts/results/component.md) 71秒、[graph](artifacts/results/graph.md) 100秒。Contract JSON は既存 artifact とバイト一致する。

**9-cell evaluator matrix**（各セルは I01 と I02 の両方を安全に導けるかを分類）：

| Contract shape | S0: profile unavailable/loading | S1: loaded, date nil | S2: loaded, date nonnil |
| --- | --- | --- | --- |
| screen | **ambiguous** — 初回空値と cached value 保持を選べず、I02 表示則もなし | **insufficient** — I01 は Repository から発見可、I02 nil rule はなし | **insufficient** — I01 は Repository から発見可、I02 date derivation はなし |
| component | **ambiguous** — `I08 normal` の適用条件も cache rule もなし | **insufficient** — `I09/I10` は output 名への link のみ | **insufficient** — `createdAt` の source/transform がない |
| graph | **ambiguous** — `I08 normal → I01/I02` edge は S0 predicate でない | **insufficient** — `I10 → I02` は nil fallback を定義しない | **insufficient** — edge は date source/formatter/output を定義しない |

S1/S2 の I01 `Profile.nickname` は target source の `ProfileMainStore.swift` と `ProfileMainContentView.swift` から **repository-discoverable** だが、いずれの contract も `I09` の source expression を指定しない。I02 は target の `Profile.createdAt` が optional であることだけを発見でき、現行 profile summary には表示されない。これは「hamii が日付から表示を要求した」証拠ではない。3 agent とも source-only で安全な content patch は書けず、silent guess を避けるには Needs Resolution とした。

**S0 の重要な反例:** pinned Product は初回に Profile が無ければ空の nickname を使う一方、再読込中・失敗時には cached/last-known nickname を維持する（各 raw result の `ProfileMainStore.swift` / `ProfileCoordinator.swift` citations）。事前固定した S0 の「未取得または loading なら displayName と membership text はまだ表示対象でない」を Product へそのまま適用すると、last-known profile 表示を損なう可能性がある。S0 を1状態として扱う設計自体を Product 統合時に検証する必要がある。この反例は事前の期待値を後付けで変更せずに残す。

**最小追加情報の候補:** state 名の列挙だけでは足りない。I01/I02 ごとに source expression、first load / cached refresh / load failure / loaded の predicate、表示・非表示、nil fallback、更新契機を結ぶ binding-to-state relation が必要である。I02 を `Profile.createdAt` から導くなら transformation と locale/calendar/time-zone 等の出力規則も必要である。graph の現行 edges は topology を示すが、predicate や transformation がない。full dependency graph が必要か、型付き relation のみで十分かはこの probe では決めない。

**Shape-independent conflict evidence:** 前の [independent review](../independent-diff-review/SPIKE.md) で I03 は3方式とも system-image intent と既存 Product avatar semantics を両立できなかった。これは state information sufficiency とは別である。現行 ADR Constraint の `unknown mapping は Needs Resolution` と整合する扱いは、衝突時に AI が overlay / fallback / replacement を無断選択しないことだが、今回の probe はその enduring policy を決定・実装したものではない。

**Limits:** 各 shape 1 agent、source-only。Human correction、runtime 表示、非 nil 日付の正確な出力、avatar/VoiceOver は未計測。Agent へ S0/S1/S2 の状況は質問として伝えたが、期待する I01/I02 出力は伝えていない。Source が存在することを contract semantics の十分性へ昇格させない。

## Conclusion

3方式とも現状の contract **単体**から S0/S1/S2 の I01/I02 意味を一意に導けない。component の state list と graph の edges は flat screen より構造を持つが、predicate と出力規則の欠落を埋めない。共通 fixture に依存した以前の成功を、contract 単体の成功として扱わない。全候補が不足し、S0 自体にも既存 Product の cached behavior との衝突があるため、粒度の採用順位はまだ決めない。Human correction は未計測だが、それだけを ADR 停滞理由にはしない。Product Integration Contract ADR は `Spike Required` を維持する。

## Artifacts

[artifacts/README.md](artifacts/README.md) に入力と prompt、[artifacts/results/](artifacts/results/) に3件の原結果を保存した。Source checkout と一時 packet は Repository 外に置いた。
