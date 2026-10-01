# Spike: Component Scope の共通検証境界

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 05 Scope Validator に対応。

## Hypothesis

同一 evaluator と closure/index projection で Human/AI/Validator の判定を一致させられる。

## Questions

同じ component はすべての入口で同じ理由で可否判定されるか。promotion で transitive reference を検査できるか。

## Prototype Scope

App/Commerce/Product/Checkout/Account tree、nested component、deny/allowOnly、promotion の小さな fixture を実装する。最初の検証は App/Checkout の nested Definition と deny policy に限定する。

## Out of Scope

既存 product repo の module 依存解析、リアルタイム共同編集。 試作 code をそのまま production code に昇格させない。

## Measurements

許可/拒否の一致率、diagnostic、promotion の変更影響、lookup latency。 対象環境、fixture、command、実装 commit と raw data を記録する。必要な成果物のみ `artifacts/` に保存する。

## Success Criteria

Human/AI/Validator が同一 rule ID と結果を返し、sibling と transitive 違反を拒否する。

## Failure Criteria

入口ごとに結果が異なる、または promotion が transitive 違反を見落とす。

## Result

`testNestedComponentAvailabilityMatchesPickerIndexAndMutation` で、App 所有の Outer → Inner の参照を作り、Inner の Checkout deny を設定した。Checkout に対し Picker、SQLite projection、Human mutation、Agent mutation が全て Outer を拒否し、mutation diagnostic は `component.denied` となった。`bash scripts/check.sh` で 19 tests 通過。Promotion 後の影響、allowOnly と複数 Scope、lookup latency は未計測。

2026-10-01 の追加検証は `ComponentScopeParitySpikeTests` の3件。fixture は App → Commerce → {Checkout, Product} と App → Account。Commerce 所有 `Outer → Inner` を nested にし、`Inner.allowOnlyScopeIDs = [Commerce, Product]` とした。`Shared` は App 所有で Account deny、`ProductOnly` は Product 所有。Current evaluator の `allowOnly` は consumer Scope の ID が列挙されている場合だけ許す。候補比較では **test-only** に allowOnly を各列挙 Scope の descendant へ拡張した。production policy は変更していない。

| Consumer | Component | Current exact membership | Candidate descendant membership |
|---|---|---|---|
| Commerce | Inner / Outer | allow | allow |
| Commerce | Shared | allow | allow |
| Commerce | ProductOnly | `scope.notAncestor` | `scope.notAncestor` |
| Checkout | Inner / Outer | `component.notAllowed` | allow |
| Checkout | Shared | allow | allow |
| Checkout | ProductOnly | `scope.notAncestor` | `scope.notAncestor` |
| Product | Inner / Outer / Shared / ProductOnly | allow | allow |
| Account | Inner / Outer / ProductOnly | `scope.notAncestor` | `scope.notAncestor` |
| Account | Shared | `component.denied` | `component.denied` |

Current evaluator の16 component × consumer 行で、`ProjectService.availableComponents`、`ProjectContextService.resources(kind: .component)`、実 SQLite `LocalIndex.components` は同じ可用集合を返した。Human / Agent の `ProjectService.mutate(.instantiate)` は各行の可否に一致し、拒否時は evaluator と同じ rule ID を返した。既存 nested-deny regression は残した。

Unsafe promotion では Checkout 所有 Outer → Checkout 所有 Inner のまま Outer だけ Commerce へ移そうとした。Human と promotion 権限のある Agent は `scope.notAncestor` で拒否され、Document、revision、`ClientPrecondition`、CanonicalSnapshot identity は変化しなかった。権限のない Agent は `approvalRequired`。Safe promotion では Inner を Commerce 所有にし、Outer を Checkout → Commerce へ変更した。Human と権限のある Agent の mutation result は同じ Document となり、実 `ProjectService` 保存で旧 client token が失効した。Outer は保存前は Checkout のみ、保存後は Commerce / Checkout / Product で利用可能、Account では不可。旧 Index は stale として拒否し、同じ新 CanonicalSnapshot から full rebuild した Index と Picker / AI context / mutation Validator の可否が一致した。これは full rebuild 経路の検証であり incremental invalidation の実証ではない。

Lookup 測定は arm64 macOS 27.0、Apple Swift 6.4 debug `swift test --filter ComponentScopeParitySpikeTests`、4 / 1000 component fixture、各30連続 sample、同じ process の `ComponentAvailability.reason` 全 component 走査と `IndexProjection(document:)` の構築を別々に測った。nearest-rank p50 / p95 (ms) の2回の成功した focused run は次の通り。最初の実装では test expectation が Canonical file loader の配列正規化を考慮せず失敗したため、製品の scope failure として扱わず、修正後の同じ source で再測定した。

| Fixture | Run | Availability p50 / p95 ms | Projection p50 / p95 ms |
|---|---:|---:|---:|
| 4 components | 1 | 0.0180 / 0.0205 | 0.0885 / 0.1002 |
| 4 components | 2 | 0.0268 / 0.0348 | 0.1313 / 0.1578 |
| 1000 components | 1 | 2.5155 / 2.6462 | 10.6741 / 11.2409 |
| 1000 components | 2 | 2.3599 / 3.1343 | 10.2078 / 12.4815 |

これは availability / projection の process 内観測値であり、Canonical read、SQLite write / Query、Git freshness、CLI startup は含まない。Product SLA や end-to-end latency とは扱わない。恒久証拠は test source とこの測定表である。

## Conclusion

共通 `ComponentAvailability.reason` の再帰判定は、検証した nested deny、複数 allowOnly ID、4 Scope の Picker / AI context / SQLite projection / Human / Agent mutation を一致させた。transitive に不正な promotion は Canonical を変更せず拒否し、安全な promotion は full Index rebuild 後に可用集合を再同期できた。**exact membership と descendant membership は Checkout で異なるため、どちらを Product Semantics とするかは ADR の Decision に残す。** この Spike から production の allowOnly rule や Index architecture を変更しない。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
