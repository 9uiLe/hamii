# hamii 管理世代を使う KnownCurrent fast path

## Related Decision

[Index consistency ADR](../../ADR.md) の低 cost な freshness 判定。[CanonicalSnapshot Spike](../consistent-canonical-snapshot/SPIKE.md) が source contents の保証境界を扱い、[Safe freshness fast path Spike](../safe-freshness-fast-path/SPIKE.md) が他の fast/slow 候補を比較する。複数 writer の許可・統合方式は [External Git Write ADR](../../../git-external-write-coordination/ADR.md) の判断事項。

## Hypothesis

**Tentative:** hamii が全 Canonical mutation を観測できる期間に限れば、取得済み `CanonicalSnapshot` から導いた `CanonicalGeneration` と、その正確な source から公開した `IndexGeneration` の対応を保持して、Query ごとの full revision scan を省ける可能性がある。観測保証が失われたら `Unknown` へ落とす。ただし `.hamii/write.lock` は save/load を直列化するだけで、別プロセスの保存を開いている Query session へ通知しない。

## Questions

- `KnownCurrent` を許す closed writer domain と lock / lease の lifetime は何か。GUI、CLI、AI、複数プロセスで全 hamii save をどう観測するか。
- `CanonicalSnapshot` の exact contents、そこから導く source revision、公開した index generation ID をどう結び付けるか。Save と index publish の間の別 writer をどう拒否するか。
- External filesystem event、branch/worktree change、process restart、sleep、event loss / overflow、watcher gap、Git attribute / filter change をいつ `Unknown` にするか。
- `Unknown` から安全に再確立する slow verification は何か。非協調 external writer を認めない場合も、どの observation gap が残るか。
- Cold open、warm steady state、hamii save、peer hamii save、external signal、branch switch 後の Query latency と slow path 率はどう変わるか。

## Prototype Scope

実 `CanonicalRepository` と `LocalIndex` を disposable Starter Git copy で使う。Test-only の process-local `KnownCurrent | Unknown | KnownStale` session を作り、save / index publication / restart / invalidation signal を制御する。Raw SQLite read は **仮の gate の後**を近似する negative-control benchmark とし、production Query と同じ安全性を持つと扱わない。通知されない external edit、実 branch switch、別 `CanonicalRepository` instance の save を挿入して false current を探す。

## Out of Scope

Production fast path の導入、watcher / cross-process epoch / lease の実装、`CanonicalRevision` algorithm の決定、外部 writer の safe collaboration policy の決定、production incremental reindex。

## Measurements

State transition と false-current 件数、cold / restart verification、warm gate、直接 SQLite、現行 production Query の p50/p95。条件は disposable Starter copy、Canonical JSON 9件（component追加後）、1 component、15 warm runs、macOS arm64、Swift 6.4 debug XCTest。単発の cold/restart 値は p95 と扱わない。

## Success Criteria

`KnownCurrent` を返す全経路で、同じ coherent CanonicalSnapshot から作った公開 IndexGeneration が current と証明できる。別 hamii writer、外部 writer、Git operation、restart / event gap を検出または `Unknown` に落とせる。証明できない範囲を API / product contract に明示し、`Unknown` なら slow verification または `staleIndex`。

## Failure Criteria

`KnownCurrent` のまま Canonical bytes が変わる、別 hamii save が未通知で通過する、watcher に event が来ないことを current の証拠とする、または index generation を別 source revision に誤って結び付ける。

## Result

**Confirmed, test-only state transitions:** cold open と simulated restart は `Unknown`。hamii save 後から index rebuild 前は `KnownStale`。rebuild 後、明示的に同じ local marker を渡した session は `KnownCurrent`。外部変更や branch switch を **通知した場合**は `Unknown`。Marker はこの test だけの整数で、Document revision でも production `CanonicalGeneration` でもない。`CanonicalSnapshot` から導出した marker と generation ID の永続的な対応は未実装。

**Confirmed failure evidence:** test-only session が `KnownCurrent` のとき、(1) canonical component file の無通知外部編集、(2) 同一 worktree の実 branch switch、(3) `.hamii/write.lock` を使う別 `CanonicalRepository` instance の save を行うと、いずれも session は `KnownCurrent` のまま旧 SQLite row を読めた。現行 `LocalIndex.components` は3ケースとも検索を拒否した。したがって process-local generation knowledge 単独、および lock が存在すること単独では safe positive fast path にならない。Peer save は同じ process の別 instance であり、cross-process IPC の検証ではない。

**Measured, one local run:**

| Operation | p50 / p95 ms | Scope |
| --- | ---: | --- |
| Test-only in-memory gate | 0.00054 / 0.00063 | 15 warm checks; source observation なし |
| Direct SQLite row query | 0.327 / 0.531 | 15 warm reads; freshness を意図的に bypass |
| Production `LocalIndex.components` | 313.66 / 357.27 | 15 warm reads; revision check を含む |
| Cold revision verification | 317.48 | 1回のみ、安全な Snapshot acquisition ではない |
| Simulated restart verification | 311.83 | 1回のみ、実 process restart ではない |

この timing 差は Query 毎の revision verification が高 cost であることを示す候補 evidence だが、direct SQLite の速さは safe fast path の性能ではない。計測条件が [End-to-end Spike](../end-to-end-index-generation/SPIKE.md) と異なるため、その p95 と直接比較しない。

**Unknown / not implemented:** safe cross-process generation notification / lease、IndexGeneration ID と source snapshot の同時 binding、実 restart / event overflow / sleep、branch switch の事前または確実な事後 invalidation、external writer の無通知変更を許す場合の positive proof、cold open からの safe recovery、production end-to-end performance。

## Conclusion

`KnownCurrent | Unknown | KnownStale` は失効を表現する有用な候補だが、今回の process-local prototype は false current を3種類再現したため採用できない。次に検証するのは「どの writer domain と observation lifetime なら positive を証明できるか」と、source snapshot と index generation の binding である。現行の `staleIndex` 拒否を維持し、Index ADR は `Spike Required`。

## Artifacts

- [KnownCurrentGenerationSpikeTests.swift](../../../../Tests/HamiiTests/KnownCurrentGenerationSpikeTests.swift): 実 CanonicalRepository / LocalIndex を使う制御された state / false-current probe。`HAMII_KNOWN_CURRENT_SPIKE_RESULT=/tmp/hamii-known-current-result.json swift test --filter KnownCurrentGenerationSpikeTests` で再計測できる。
- [known-current-result.json](artifacts/known-current-result.json): 上記1 run の状態、timing、制約。
