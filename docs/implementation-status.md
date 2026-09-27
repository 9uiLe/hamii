# 実装状況

hamii で現在実行できる範囲を示します。製品境界と依存規則は [Current Architecture](final-architecture.md)、未確定の技術判断は [`adr/`](../adr/) にあります。

| 分類 | 現在の状態 |
|---|---|
| Aligned | Native-semantic IR が編集の正本です。GUI と CLI は `ProjectService` と同じ検証 pipeline を使います。ArchitectureScope ownership、component reference、target capability declaration、Git の分割 JSON、使い捨て SQLite query index、CLI skills、独立した format preflight を実装しています。 |
| Needs Refactor | Canvas は小さな SwiftUI editor です。IR が扱う意味を落とさず、描画と Inspector を拡張する必要があります。Canonical save の process-crash recovery は実装済みですが、停電耐久性は未確立です。同じ worktree の非協調 writer は Product Contract 外です。Query index は現在 full rebuild です。 |
| Missing | iOS Simulator / Android Preview Host、product repository integration adapter、historical format transformation edge、semantic merge、state を保持する runtime reconciliation、custom native component build、remote asset cache、Interaction と Token の全種別の編集機能。 |
| Obsolete | Runtime の legacy format parser、MCP adapter、GUI/CLI 別々の mutation engine は package に含めません。 |
| Unresolved | 狭い決定境界と必要な調査・計測は ADR queue にあります。 |

現在実行できる Native Preview は、宣言済みの Stack / Text / Button / System Image と Text value patch を扱う macOS SwiftUI 実装、および編集用 Canvas です。他の Target / Framework declaration は model の入力であり、宣言だけで Preview Host が利用可能にはなりません。Standalone source generation は静的 SwiftUI subset を扱い、未対応 semantics を error として報告します。Repository Asset は content-addressed blob として取り込めますが、その blob の Native Preview 描画は未実装です。

`HamiiNativeRuntime` は iOS 26.5 Simulator SDK 向けに Swift 6.4 で compile できます。iOS Host の session protocol は [Host Session Spike](../adr/preview-host-transport/spikes/session-recovery/SPIKE.md) で検証中です。現在の環境では Simulator boot 中の audio/AV capture 初期化が XPC reply 待ちで timeout し、Host install より前に `simctl boot` が失敗します。これは transport validation の blocker です。Host の runtime behavior、画面、transport latency / recovery は未測定・未確認です。

Spacing Token は GUI と CLI から作成・参照・Stack spacing / container padding へ指定できます。Canvas と macOS Native Preview は alias を解決して同じ値を適用します。その他の Token kind の解決と Inspector は未実装です。

`bash scripts/check.sh` は実装済み契約を検証します。この検証だけでは Native Preview parity、次の format change に対する migration safety、production integration の品質は証明できません。これらは [Technical Spikes](spikes.md) に紐づく実験で測定します。

Canonical save は読み込み時点の Document から期待 Canonical bytes を再構成し、保存直前の現在 bytes と照合します。load/save 間の逐次外部編集では conflict を返し、外部 bytes を保持することを統合テストで確認しました。照合と atomic replace の間に非協調 writer が入る race は未解決で、[External Git Write ADR](../adr/git-external-write-coordination/ADR.md) の対象です。

`WorktreeCoordinator` が Canonical save、managed `git switch`、CLI query / rebuild、validated merge publication の同一 lock と pending gate を所有します。`git switch` は client token を開始時に失効させます。`git merge check` は一時 worktree で semantic validation と一時 Index rebuild を行い、source worktree を変更しません。`git merge publish` は検証済み candidate commit を ref CAS で公開し、Canonical 検証と同じ Snapshot に由来する full Index rebuild の後に gate を解除します。`git recover` は中断した managed switch または publication の既知状態だけを回復し、所有者不明の Git lock が存在すれば pending gate を維持して拒否します。Coordinated `CanonicalGeneration` と Index の typed source binding / generation ID は production で記録します。一般 Query の自動 full rebuild policy は coordinated・検証可能な Canonical state の Derived Index failure に限定する Decision が済んでいますが、production recovery service は未実装です。増分再索引の適用条件と停電耐久性は未確定です。

`hamii query components` は `IndexQuerySession` を使います。Session は初回の coordinated Snapshot / Git oracle verification で `Bound(G)` Index だけに process-local witness を発行し、同じ process の次回 Query は共有 CanonicalGeneration と公開 Index descriptor を同じ lock 内で照合して rows を読みます。CLI は command ごとに新 process なので毎回 cold slow verification です。現 Editor の Component 一覧は `ProjectService.availableComponents` を使用し、`IndexQuerySession` はまだ利用していません。`ExplicitlyUnbound` は exact Snapshot と Git oracle に一致した場合だけ slow Query を許可し、witness を発行しません。Binding の欠損・破損、Canonical source の不一致、Git の `assume-unchanged` / `skip-worktree` や filter による不確実な状態では rows を返しません。外部変更後の baseline は `staleIndex` → 明示的 `hamii index rebuild` → verified slow Query です。任意の同時外部書込への保証はありません。

[Production Query session measurement](index-query-performance.md) では arm64 macOS 27.0 / Swift 6.4 debug の 1/1000/5000 Component fixture で同一 process warm p95 2.038 / 2.766 / 5.371 ms、cold slow p95 385.189 / 643.113 / 1682.507 ms です。別の Starter copy / 40-run one-shot CLI p95 は 378.192 ms でした。これらは異なる実行条件の値であり Product SLA ではありません。自動 full rebuild、増分再索引、failure / retry UX は [Index Recovery Strategy ADR](../adr/index-recovery-strategy/ADR.md) の検証対象です。
