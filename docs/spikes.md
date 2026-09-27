# hamii Technical Spikes

Status: 検証中。各 Spike は fixture、対象 OS/SDK/Xcode、実行 command、測定値、screenshot/event/a11y trace、失敗、判断更新を該当する範囲で記録する。pending ADR に対応する検証は [`adr/<name>/spikes/<spike-name>/SPIKE.md`](../adr/) を計画と結果の正本とし、成果物は各 Spike ディレクトリの `artifacts/` に置く。横断的な検証だけ `research/spikes/<id>/` に置く。数値目標は実験前に固定し、測定後に変更しない。P0 failure は製品の Preview/IR 約束を改訂する。

| ID | Priority | Hypothesis and prototype | Evidence / pass-fail gate |
|---|---|---|---|
| **01 IR** | P0 | Text/Image/Button/Stack/Scroll/Navigation/Toolbar、binding/token/asset ref、target override、ordered effects を持つ最小 Current IR を作る。SwiftUI/UIKit の代表 screen corpus を encoding する。 | Schema validation、stable ID、round-trip、capability loss report。主要画面が opaque field に依存すれば taxonomy を改訂。 |
| **02 SwiftUI Runtime** | P0 | 事前 compile した renderer が Target Plan を SwiftUI view に変換し、text/padding/state/fixture を data 更新する。 | edit→frame latency、focus/scroll/state identity、a11y tree。値変更で compile が発生すれば Preview 仮説は失敗。 |
| **03 UIKit Runtime** | P1 | ID→UIView/UIViewController registry、UIStackView、UINavigationController、toolbar を組み立て patch/reconcile。 | Auto Layout warning/main-thread violation/controller lifecycle、patch→frame。system bar を frame hack する必要があれば capability を縮小。 |
| **04 Patch Runtime** | P0 | Host protocol の snapshot、ordered patch/ack、欠番、再接続、subtree refresh を SwiftUI で実装。 | revision と frame の一致、state reset diagnostics、compile なし子移動。stale frame が current 表示されたら失敗。 |
| **05 Scope Validator** | P0 | App/Commerce/Product/Checkout/Account tree、nested component dependency、promotion を同じ evaluator で判定。 | Human/AI/Picker/Query/Validator が同じ許可・拒否理由を返す。sibling が通れば失敗。 |
| **06 Component Variant** | P1 | Definition+axes+sparse deltas+instance overrides を実装し 1k instance を解決。 | Definition edit の依存 invalidation、instance edit の局所性、cycle/error、保存に subtree copy が無いこと。 |
| **07 Authoring Harness** | P0 | tokenOnly、absolutePositioning forbidden、component availability、a11y rule を versioned policy にする。 | 同じ違反を Human/AI command が同一 rule ID で拒否し、waiver が監査されること。Prompt だけで成立したら失敗。 |
| **08 Git Repository Storage** | P0 | stable ID shards と atomic multi-file save、二人の branch edit/pull/merge、crash during save を再現。 | untouched entities に diff が出ない、complete old/new revision へ recovery、merge 後 validation。torn canonical graph が残れば失敗。 |
| **09 Local Query DB** | P1 | 1k/10k/50k Layer、Scope closure、component/token/asset usage を SQLite に index。pull/外部編集を incremental reindex。 | query p50/p95、index rebuild 時間、fingerprint drift 検知。破損 DB を消して正本から復旧できること。 |
| **10 Migration** | P0 | v1→v2→v3 edge、別 target の historical types、temporary worktree、fresh index rebuild。 | Core の依存 graph に legacy type が無いこと、元 tree 不変、同一結果への repeatability。 |
| **11 Destructive Migration** | P1 | literal color→token の複数候補、missing asset、unsupported component を入力。 | Requires Resolution と影響 diff、blocking report、review/commit 前は元 tree 不変。曖昧値の自動推測は失敗。 |
| **12 Asset Storage** | P1 | small Git、large LFS、remote URL/cache、runtime binding、hash object、offline を検証。 | hash integrity、LFS missing preflight、cache 削除後も document 正常、secret URL 拒否。repo size/clone time も測る。 |
| **13 AI Context** | P1 | selection edit、scope-aware component 探索、token 更新、stale revision を 1k/10k fixture で試す。 | task success、送信 token/bytes、query count、scope violation、conflict detection。全 document dump が常用なら設計を改訂。 |
| **14 Product Integration** | P1 | 同じ ProfileHeader contract を異なる実 repository convention（例 MVVM/TCA）へ AI が接続。 | reviewable diff、build/test、binding/event/token/a11y contract の対応表。未知 mapping を silent guess すれば失敗。 |

## Pending ADR と個別 Spike

下表の ID は計画上の分類。個別実験の計画と結果の正本は次の `SPIKE.md`。

- [Scope-aware AI Context Retrieval](../adr/ai-context-retrieval/spikes/scope-aware-context/SPIKE.md)
- [Git / LFS threshold and availability](../adr/asset-storage-policy/spikes/git-lfs-threshold/SPIKE.md)
- [Authoring Harness の共通 policy 実行](../adr/authoring-policy-enforcement/spikes/actor-policy-parity/SPIKE.md)
- [Large Canvas benchmark](../adr/canvas-renderer-performance/spikes/large-canvas/SPIKE.md)
- [Capability の契約粒度](../adr/capability-contract/spikes/capability-granularity/SPIKE.md)
- [Component Scope の共通検証境界](../adr/component-scope-validation/spikes/scope-rule-parity/SPIKE.md)
- [Component Variant と Instance の解決](../adr/component-variant-resolution/spikes/instance-resolution/SPIKE.md)
- [Compose IR validation](../adr/compose-target-timing/spikes/compose-ir-validation/SPIKE.md)
- [Custom Component artifact update](../adr/custom-component-loading/spikes/artifact-update/SPIKE.md)
- [Shard and merge benchmark](../adr/git-canonical-sharding/spikes/shard-merge-benchmark/SPIKE.md)
- [External writer interleaving](../adr/git-external-write-coordination/spikes/external-writer-interleaving/SPIKE.md)
- [Worktree isolation](../adr/git-external-write-coordination/spikes/worktree-isolation/SPIKE.md)
- [External change detection](../adr/git-external-write-coordination/spikes/external-change-detection/SPIKE.md)
- [Concurrent worktree merge](../adr/git-external-write-coordination/spikes/concurrent-worktree-merge/SPIKE.md)
- [Automatic full index rebuild](../adr/index-recovery-strategy/spikes/automatic-full-rebuild/SPIKE.md)
- [Incremental reindex](../adr/incremental-index-recovery/spikes/incremental-reindex/SPIKE.md)
- [Automatic Index Recovery eligibility](../adr/index-recovery-strategy/spikes/recovery-eligibility/SPIKE.md)
- [Large project index rebuild](../adr/incremental-index-recovery/spikes/large-project-rebuild/SPIKE.md)
- [Isolated format upgrade](../adr/migration-core-boundary/spikes/isolated-format-upgrade/SPIKE.md)
- [Ambiguous value review](../adr/migration-ambiguity-resolution/spikes/ambiguous-value-review/SPIKE.md)
- [Migration worktree safety](../adr/migration-review-protocol/spikes/worktree-safety/SPIKE.md)
- [Host/source conformance](../adr/native-preview-parity/spikes/host-source-conformance/SPIKE.md)
- [Native-semantic IR の最小 taxonomy](../adr/native-semantic-ir/spikes/minimal-ir/SPIKE.md)
- [Frame capture and revision fidelity](../adr/preview-frame-capture/spikes/frame-latency/SPIKE.md)
- [Host session and recovery](../adr/preview-host-transport/spikes/session-recovery/SPIKE.md)
- [Preview input routing](../adr/preview-input-forwarding/spikes/input-routing/SPIKE.md)
- [Product Integration Contract の実証](../adr/product-integration-contract/spikes/repository-mapping/SPIKE.md)
- [Remote cache and offline behavior](../adr/remote-asset-cache/spikes/offline-cache/SPIKE.md)
- [Value patch without compilation](../adr/swiftui-reconciliation/spikes/value-patch/SPIKE.md)
- [SwiftUI Host reconciliation and state identity](../adr/swiftui-reconciliation/spikes/state-reconciliation/SPIKE.md)
- [UIKit Preview の MVP inclusion](../adr/uikit-mvp-boundary/spikes/uikit-host-feasibility/SPIKE.md)
- [Swift Macro metadata prototype](../adr/macro-driven-domain-metadata/spikes/metadata-prototype/SPIKE.md)
- [Android Preview frame/input feasibility](../adr/android-preview-transport/spikes/frame-input-feasibility/SPIKE.md)
- [Stable ID concurrent edit identities](../adr/stable-id-strategy/spikes/concurrent-edit-identities/SPIKE.md)

各 `SPIKE.md` の `Result` / `Conclusion` と同じディレクトリ内の成果物を根拠に判断する。結果を先に commit し、実装・検証を終え、恒久 docs/実装へ移した後の別 commit で個別 ADR ディレクトリを削除する。[ADR workflow](adr-workflow.md) を参照。

## Additional cross-cutting measurements

- **Native parity:** [Host/source conformance](../adr/native-preview-parity/spikes/host-source-conformance/SPIKE.md) — 同じ IR/fixture/OS で Host と generated app の bounds、visual、a11y tree、event trace を別々に比較。Pixel average 単独で合格させない。
- **Canvas:** [Large Canvas benchmark](../adr/canvas-renderer-performance/spikes/large-canvas/SPIKE.md) — 1k/10k/50k Layer で viewport culling、LOD、selection、memory pressure と pan/zoom frame p95 を測り、必要なら Metal を比較。
- **Custom Native Component:** [Artifact update](../adr/custom-component-loading/spikes/artifact-update/SPIKE.md) — source 変更後の build/relink/install/signing/Host restart 範囲を記録。「Component Build が軽い」は計測まで claim しない。
- **Compose/CMP timing:** [Compose IR validation](../adr/compose-target-timing/spikes/compose-ir-validation/SPIKE.md) — Spike 01 の IR が SwiftUI/UIKit で固まる前に Compose Android の小さな lowering を作り、portable semantics の歪みを見つける。CMP iOS Host は Android Host と別 artifact として Later に検証する。[JetBrains platform specifics](https://kotlinlang.org/docs/multiplatform/compose-platform-specifics.html)。

## Decision gates

1. **Phase 0 gate:** Spike 01 が native 意味と target loss を表現できる。
2. **Preview gate:** Spike 02/04 が supported value/structure edits で compile 不要、revision 正確、失う state を明示できる。
3. **Authoring gate:** Spike 05/07 が actor に依らず同じ rule を enforce できる。
4. **Persistence gate:** Spike 08/09/10/11 が recovery、rebuild、reviewable migration を示す。
5. **MVP gate:** Spike 13/14 と parity が end-to-end UI Intent の transfer を示す。
