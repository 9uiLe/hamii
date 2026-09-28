# Affected Projection Dependency Capture

## Related Decision

[Incremental Index Recovery の適用境界](../../ADR.md)。この Spike は affected projection key の **complete superset** を、old full Document を保持せず計算できるかを調べる。Incremental recovery の採否は決めない。

## Hypothesis

現行 v1 `IndexProjection` の valid old/new Document 間では、exact ChangedEntitySet、current validated Document、published old component / scope-closure rows、old per-Screen usage summary から、変更されたすべての projection row key を包含できる。Component dependency の old direct-edge summary は correctness の必要条件と先に仮定しない。

Component `X` の Canonical bytes が変わらなければ、`X` の outgoing dependency edges も変わらない。old-only edge を除去した owner は Changed Component set `C` に入る。その owner の上流にいる unchanged dependent は current graph の reverse closure で到達できる、という反証可能な仮説を検証する。Scope ancestry の変化は別 branch で扱う。

## Questions

- `C ∪ reverseClosure(currentGraph, C)` は Component availability の変更をすべて包含するか。old/new graph の和集合、全 Component fallback とどの程度異なるか。
- Changed Screen の旧 usage 寄与を、published aggregate `usage_count` だけから復元できるか。
- 既存の old `scope_closure` は Scope subtree の旧 ancestry evidence として十分か。
- Historical summary の世代結合・破損時 fallback を fail closed にできるか。
- Summary と planning の費用は full projection と比較してどうか。

## Prototype Scope

- `Tests/HamiiTests/AffectedProjectionDependencySpikeTests.swift` に test-only planner と SQLite summary store を置く。Production `IndexProjection`、`LocalIndex`、recovery schema は変更しない。
- Planner は `ChangedEntitySet`、current Document、old published rows、old per-Screen usage summary のみを使う。old full Document と full new projection は planner へ渡さない。Component old graph は比較 oracle にのみ使用する。
- `component:<id>`、`closure:<consumer>:<ancestor>`、`availability:<consumer>:<component>` の実 projection row key を出す。Planner 後に full old/new `IndexProjection` を oracle として作り、`ActualChangedKeys ⊆ PlannedKeys` と patched old rows == full new rows を確認する。
- Component graph 抽出は現行 `ComponentAvailability` と同じ `Layer.component`、`Layer.children`、`ComponentInstance.slotContent` を辿る。Screen usage は現行 `IndexProjection.collectUsage` と同じく `Layer.component` と `Layer.children` のみを辿る。
- old summary / rows / generation identity は試作用 SQLite transaction にまとめる。失われた・破損した・世代が違う summary は incremental 不可として扱う。

## Out of Scope

- Targeted projector、production incremental recovery、production Index schema、generation file publication、Index fast path の採用。
- 任意 external writer 下の CanonicalSnapshot 安全性。Snapshot / source capture は既存の coordinated boundary と前段の [Changed-entity Source Capture](../changed-entity-source-capture/SPIKE.md) の Evidence を前提にする。
- full new projection を使った planned key 計算。Oracle の replacement value は full projection から取り、targeted recomputation の証明にはしない。

## Measurements

Swift 6.4 / macOS / debug XCTest、各性能 fixture 5 runs。p50 / p95 はこの環境の局所値。Canonical read、Git、CLI、targeted projector、production publication は含まない。全 raw result は [artifacts/benchmark.json](artifacts/benchmark.json)。

| Fixture | Actual / planned rows | Combined planner p50 / p95 | Full projection p50 / p95 | Usage summary only SQLite read p50 |
| --- | ---: | ---: | ---: | ---: |
| 1000 independent Components | 3 / 13 | 2.34 / 2.37 ms | 9.47 / 9.49 ms | 0.10 ms |
| 5000 independent Components | 3 / 13 | 11.77 / 13.40 ms | 47.45 / 50.48 ms | 0.20 ms |
| mixed: 100 Components, 12 Scopes, 21 Screens | 3 / 37 | 0.48 / 0.49 ms | 2.51 / 2.56 ms | 0.09 ms |
| 100 Component chain | 99 / 397 | 0.88 / 0.89 ms | 73.75 / 73.90 ms | 0.09 ms |
| 500 Component fanout | 499 / 1997 | 3.94 / 3.97 ms | 11.77 / 11.82 ms | 0.09 ms |

試作用 SQLite store は **全 Index row の読み書きと digest 検証も含む**。5000 Component でその read p50 は 244.51 ms、write p50 は 285.60 ms。これは per-Screen summary の限界費用でも production implementation の費用でもない。`usageSummarySQLiteReadOnly` は summary と identity だけを読む分離測定であり、単独では published Index rows の整合性を証明しない。Planner p50 は 5000 Component で full projection の約 25% だが、source capture / inventory diff / row integrity / targeted projection / publication を含まないため end-to-end の便益は未証明。

## Success Criteria

- Valid old/new の tested cases 全件で `ActualChangedKeys ⊆ PlannedKeys`、patched rows == full new projection、false negative 0。
- Current-only graph、old/new union graph、all Components fallback の影響集合を比較できる。
- Same aggregate usage / different changed-Screen contribution の反例を示せる。
- old `scope_closure` から Scope move / delete / reparent の旧影響 consumer を拾える。
- Test-only summary が旧 Index generation / source identity に結合し、破損・欠落・version 不一致・identity 不一致で fallback する。
- 新 OS process で summary を再読込でき、後続 save が captured plan を失効させる。
- Performance と over-invalidation を分けて記録する。

## Failure Criteria

- Valid old/new pair で実 row change を missed affected key にする。
- Valid Component `X ∉ C` の availability が変わり、かつ `X ∉ reverseClosure(currentGraph, C)` となる。
- Planner が old full Document / full new projection を必要とする。
- 不完全 summary の一部だけを信用する、または後続 Canonical transition の後も旧 plan を publish 可能と扱う。

## Result

**Confirmed for tested cases:** 13 Component scenarios、14 Screen / Scope / combined scenarios と 384 組の deterministic acyclic graph transition はすべて full projection oracle を包含し、patched rows が一致した。384 組で Component availability が変わった延べ 228 Component に対し false negative は 0。current-only と old/new union の影響集合差は 0。[component matrix](artifacts/component-matrix.json)、[Screen / Scope matrix](artifacts/screen-scope-matrix.json)、[graph enumeration](artifacts/graph-enumeration.json) に case 別の結果を置く。

**Confirmed for tested cases:** old edge removal は edge owner が `C` に入り、unchanged `X → owner` は current graph から到達できた。Component delete / add、stable-ID rename、nested children、slotContent、availability policy、ownerScope change でも同じ gate を通過した。Scope parent move、descendants、add/delete/reparent、name-only と Screen usage 追加/削除、count 2→1、count 1→0、Screen name-only、combined change も欠落 0。name-only / native-only では過剰失効を明示的に観測した。

**Confirmed:** 同じ published aggregate component rows を持つ2つの old Document でも、changed Screen の旧 usage 寄与が異なると必要な component row 更新が異なる。Per-Screen historical usage evidence が無い場合、aggregate から正確な delta は復元できない。

**Confirmed for test-only SQLite:** rows、summary、generation/source metadata を1 transaction で公開すると、commit 前の reader は旧 generation、commit 後は新 generation を見た。rollback 後は旧 generation が残った。summary 欠落、重複、count 破損、version / source / generation 不一致、row 破損は read を拒否した。これは SQLite logical transaction visibility の Evidence であり、production file publication / crash / power-loss の証明ではない。

**Confirmed for tested restart:** 実 Canonical repository の single-pass byte-digest capture から得た変更集合を、新 OS process が旧 SQLite summary と current Document と組み合わせ、親 process と同じ affected key set を作った。その後の save で captured source identity が変わり旧 plan を publish 候補から外した。一般的な arbitrary external writer の保証には拡張しない。

## Conclusion

現行 v1 の tested valid→valid transitions では、old Component direct-edge summary の correctness 上の必要性は示されなかった。Current graph の reverse closure と changed-owner seed が十分な候補である。ただし将来の `ComponentAvailability` semantics、未試験 graph、production changed-source integration へ一般化しない。Historical metadata の候補は現時点で source inventory、per-Screen usage、既存 old scope-closure rows に絞る。

Planner の局所費用は full projection より小さい fixture があるが、試作用 full-row SQLite container と source acquisition を含む end-to-end 効率は未解決。Dependency density が高い chain / fanout では planned rows が広い。**Targeted projector の Spike へ自動進行しない**。Index ADR の `Spike Required` を維持し、summary の限界 storage cost、targeted recomputation、production generation / publication、source capture から Query までの費用を次の stop gate とする。

## Artifacts

- [Component scenario matrix](artifacts/component-matrix.json)
- [Screen / Scope scenario matrix](artifacts/screen-scope-matrix.json)
- [Graph enumeration](artifacts/graph-enumeration.json)
- [Benchmark](artifacts/benchmark.json)
- Executable test: `swift test --filter AffectedProjectionDependencySpikeTests`
