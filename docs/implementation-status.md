# 実装状況

hamii で現在実行できる範囲を示します。製品境界と依存規則は [Current Architecture](final-architecture.md)、未確定の技術判断は [`adr/`](../adr/) にあります。

| 分類 | 現在の状態 |
|---|---|
| Aligned | Native-semantic IR が編集の正本です。GUI と CLI は `ProjectService` と同じ検証 pipeline を使います。ArchitectureScope ownership、component reference、target capability declaration、Git の分割 JSON、使い捨て SQLite query index、CLI skills、独立した format preflight を実装しています。 |
| Needs Refactor | Canvas は小さな SwiftUI editor です。IR が扱う意味を落とさず、描画と Inspector を拡張する必要があります。Canonical save の process-crash recovery は実装済みですが、停電耐久性と非協調外部 Git 書込の lossless 保証は未確立です。Query index は現在 full rebuild です。 |
| Missing | iOS Simulator / Android Preview Host、product repository integration adapter、historical format transformation edge、semantic merge、state を保持する runtime reconciliation、custom native component build、remote asset cache、Interaction と Token の全種別の編集機能。 |
| Obsolete | Runtime の legacy format parser、MCP adapter、GUI/CLI 別々の mutation engine は package に含めません。 |
| Unresolved | 狭い決定境界と必要な調査・計測は ADR queue にあります。 |

現在実行できる Native Preview は、宣言済みの Stack / Text / Button / System Image と Text value patch を扱う macOS SwiftUI 実装、および編集用 Canvas です。他の Target / Framework declaration は model の入力であり、宣言だけで Preview Host が利用可能にはなりません。Standalone source generation は静的 SwiftUI subset を扱い、未対応 semantics を error として報告します。Repository Asset は content-addressed blob として取り込めますが、その blob の Native Preview 描画は未実装です。

`HamiiNativeRuntime` は iOS 26.5 Simulator SDK 向けに Swift 6.4 で compile できます。iOS Host の session protocol は [Host Session Spike](../adr/preview-host-transport/spikes/session-recovery/SPIKE.md) で検証中です。この環境では Simulator 起動が CoreSimulatorService 接続断で失敗したため、Host の runtime behavior と画面は未確認です。

Spacing Token は GUI と CLI から作成・参照・Stack spacing / container padding へ指定できます。Canvas と macOS Native Preview は alias を解決して同じ値を適用します。その他の Token kind の解決と Inspector は未実装です。

`bash scripts/check.sh` は実装済み契約を検証します。この検証だけでは Native Preview parity、次の format change に対する migration safety、production integration の品質は証明できません。これらは [Technical Spikes](spikes.md) に紐づく実験で測定します。

`hamii query components` は Source Fingerprint の不一致を `staleIndex` として拒否します。外部変更後は `hamii index rebuild` で再構築してください。再構築は full rebuild であり、Git の同時書込と増分再索引は [Index ADR](../adr/index-consistency/ADR.md) の検証対象です。
