# Targeted Projection Recompute

## Related Decision

[Incremental Index Recovery の適用境界](../../ADR.md)。`ChangedEntitySet` と affected keys から replacement rows を直接作れるかを調べる。Production incremental recovery の採否は決めない。

## Hypothesis

現行 v1 `IndexProjection` では、current validated Document、key-scoped old Index access、published source identity、affected-key plan から、full new projection を作らず planned rows の replacement/delete を得られる。Screen usage は U1（historical per-Screen delta）と U2（current Screens rescan）の両方が正しいが、cost と over-invalidation が異なる。

## Questions

- Component、Scope closure、availability の planned row だけを production evaluator と同じ意味で再計算できるか。
- U1 と U2 はそれぞれどの historical input、Screen traversal、affected-key 範囲を要するか。
- Planner + targeted projector + changed-entity detection は full projection と比較してどの change class で有利か。
- Source binding、summary corruption、後続 Canonical transition を fail closed にできるか。

## Prototype Scope

- `Tests/HamiiTests/AffectedProjectionDependencySpikeTests.swift` に test-only `KeyedOldIndex`、`TargetedPatch`、keyed planner、targeted projector を追加。Old projection values は SQLite から planned Component ID だけ読む。Old Component/Scope ID の列挙と affected closure key の lookup は行う。U1 summary integrity preflight は usage summary 全体を読むが、projection rows 全体は読まない。
- Candidate は `IndexProjection(current)`、全 Component row、全 closure、全 availability matrix を構築しない。Full `IndexProjection` は candidate 完了後の oracle にのみ用いる。
- Screen traversal は現行 `IndexProjection.collectUsage` と同じ `Layer.component` + `Layer.children` のみ。Component dependency graph は現行 availability evaluator と同じ slot content を含む。Availability の replacement は production `ComponentAvailability.reason` を呼ぶ。
- U1 は old aggregate usage − changed Screen の old contribution + changed Screen の current contribution。U2 は current 全 Screen を走査し、changed Screen がある場合は historical per-Screen summary を要しない保守的計画として全 old/current Component row を affected に入れる。
- Old generation/source/version が合わない場合、また U1 の summary が欠落・破損した場合は candidate を開始しない。Candidate patch は old Index generation/source と new Canonical generation/identity を別 field に保持する。

## Out of Scope

- Production LocalIndex schema、production source inventory、incremental recovery、atomic generation publication、Query 接続、full/incremental crossover の決定。
- CanonicalSnapshot acquisition、Git observation、non-coordinated writer、power loss。Test-only keyed SQLite setup の cost は benchmark の候補内に含めない。
- Test-only patch の publication。`isBound` は source identity mismatch を拒否する候補であり、production publication gate の証明ではない。

## Measurements

Swift 6.4 / macOS / debug XCTest、各 fixture 5 runs、p50/p95 はこの環境だけの値。Raw data は [benchmark.json](artifacts/benchmark.json)。`integratedCompute` は **in-memory old/new Document の全 entity を JSON 再シリアライズする合成 inventory diff** → changed set → keyed planner → targeted projector。CanonicalSnapshot、Git、Index publication、Query、old SQLite setup は含まない。Production の source inventory diff と同一費用ではない。

| Change class / fixture | U1 / U2 planned / total rows | Full projection p95 | Targeted U1 / U2 p95 | Integrated U1 / U2 p95 |
| --- | ---: | ---: | ---: | ---: |
| Component local / 1000 independent | 13 / 13 / 5008 | 9.48 ms | 3.91 / 3.59 ms | 42.30 / 41.91 ms |
| Availability / 5000 independent | 13 / 13 / 25005 | 47.41 ms | 18.27 / 18.17 ms | 211.10 / 212.28 ms |
| Scope topology / 100 | 207 / 207 / 510 | 1.13 ms | 1.64 / 1.58 ms | 5.67 / 5.58 ms |
| Component chain / 100 | 397 / 397 / 409 | 74.66 ms | 75.85 / 77.39 ms | 82.39 / 83.90 ms |
| Component fanout / 500 | 1997 / 1997 / 2009 | 11.95 ms | 18.16 / 17.91 ms | 50.42 / 50.16 ms |
| Screen usage / 121 Screens, 100 Components | 1 / 100 / 508 | 3.25 ms | 1.22 / 3.01 ms | 94.37 / 95.84 ms |
| Combined / 100 | 214 / 313 / 507 | 1.14 ms | 1.64 / 1.73 ms | 5.64 / 5.82 ms |

1000 / 5000 Component の U1 integrated p95 のうち、合成 inventory diff はそれぞれ 38.35 / 192.29 ms。Keyed SELECT は 0.37 / 1.78 ms、evaluation context は 1.65 / 8.65 ms。Usage-heavy の U1 / U2 usage recompute p95 は 0.05 / 2.28 ms、Screen visits は 1 / 121。U1 の historical summary は test-only SQLite preflight で全 summary entry の digest を再確認しており、その storage / read cost と production publication contract は別途必要。細部の p50/p95、planner、closure、availability、visit counts は raw artifact に記録する。

## Success Criteria

- Candidate は full new projection と old projection value 全走査を行わず、planned replacement/delete のみ生成する。
- Replacement value が full oracle の同 key と一致し、patched old rows が full new rows と一致する。
- 13 Component と 14 Screen/Scope を U1/U2 で、384 graph pairs を U1 で、multi-Screen + newly used Component を U1/U2 で検証する。
- U1 / U2 の両方を Screen usage の add/remove/delete/count change で比較する。
- Closure は affected consumer、availability は planned pair だけ評価する。
- Old source/summary corruption は拒否し、後続 source change は patch を失効させる。
- Planner、old keyed lookup、context、U1/U2 usage、closure、availability、integrated cost を full projection と分けて測る。
- Production Index/recovery は変更しない。

## Failure Criteria

- Full new projection または全 old projection values を candidate の入力に使う。
- Planned key の replacement が full oracle と異なる、または patched rows が一致しない。
- Broken summary を部分的に信用する。Source change 後も patch を有効と扱う。
- 局所 change class でも targeted recompute が full projection と同程度以上、または planned keys がほぼ全 rows に広がるなら、その class を incremental 採用候補として扱わない。

## Result

**Confirmed for tested v1 cases:** 13 Component cases、14 Screen/Scope cases、2 changed Screens + new Component usage では U1/U2 双方の candidate が full oracle と一致した。384 deterministic acyclic graph pairs は U1 で一致し、current-only reverse closure の false result は 0。これは任意 graph / 将来の semantics の一般証明ではない。Current production `ComponentAvailability.reason` を planned availability pair に直接適用した。

**Confirmed for test-only input boundary:** Old component value SELECT は planned Component ID 以下の件数だった。Old projection value の full scan は candidate にない。U1 は source/generation/version/usage digest mismatch または count 破損で開始せず、U2 は per-Screen summary 欠落でも current Screen rescan により tested case を再計算した。U2 も published projection rows / source binding が検証済みであることを前提とする。後続 Canonical save により patch の to-identity が一致しなくなった。

**Measured, not Product SLA:** 局所 Component 変更では targeted 部分だけを見ると full projection より速い。今回の integrated 値は合成 inventory diff が支配し、full projection より遅い。Scope、chain、fanout、combined では affected rows が多く、targeted 単体も full と同等以上だった。Usage-heavy は U1 が 1 row、U2 が 100 Component rows を計画し、U2 は 121 Screen / 約 3700 Layer を再走査した。Per-Screen summary は局所 delta の費用削減には有望だが、correctness の絶対必須条件ではない。

## Conclusion

現行 v1 semantics の tested cases では targeted replacement を直接計算できた。経済性は change class と source inventory diff の実装に強く依存する。特に chain/fanout/Scope topology は full rebuild 候補、局所 Component / Screen usage は incremental 候補として **追加検証する余地** がある。まだ適用境界も production schema も決めない。次の gate は、production-shaped changed-entity capture と candidate generation publication を含む費用・正しさであり、今回の test-only integrated 値を production end-to-end と呼ばない。親 ADR は `Spike Required` を維持する。

## Artifacts

- [Five-run benchmark raw results](artifacts/benchmark.json)
- Executable correctness and benchmark test: `swift test --filter AffectedProjectionDependencySpikeTests`
- Benchmark opt-in: `HAMII_TARGETED_BENCHMARK_RESULT=<path> swift test --filter AffectedProjectionDependencySpikeTests.testMeasuredTargetedProjectionCost`
