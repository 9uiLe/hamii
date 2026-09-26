# 実装状況

hamii で現在実行できる範囲を示します。製品境界と依存規則は [Current Architecture](final-architecture.md)、未確定の技術判断は [`adr/`](../adr/) にあります。

| 分類 | 現在の状態 |
|---|---|
| Aligned | Native-semantic IR が編集の正本です。GUI と CLI は `ProjectService` と同じ検証 pipeline を使います。ArchitectureScope ownership、component reference、target capability declaration、Git の分割 JSON、使い捨て SQLite query index、CLI skills、独立した format preflight を実装しています。 |
| Needs Refactor | Canvas は小さな SwiftUI editor です。IR が扱う意味を落とさず、描画と Inspector を拡張する必要があります。Canonical save の process-crash recovery は実装済みですが、停電耐久性と外部 Git 書込との同時性は未検証です。Query index は現在 full rebuild です。 |
| Missing | iOS Simulator / Android Preview Host、product repository integration adapter、historical format transformation edge、semantic merge、state を保持する runtime reconciliation、custom native component build、remote asset cache、Interaction と Token の全種別の編集機能。 |
| Obsolete | Runtime の legacy format parser、MCP adapter、GUI/CLI 別々の mutation engine は package に含めません。 |
| Unresolved | 狭い決定境界と必要な調査・計測は ADR queue にあります。 |

現在実行できる Native Preview は、宣言済みの Stack / Text / Button / System Image と Text value patch を扱う macOS SwiftUI 実装、および編集用 Canvas です。他の Target / Framework declaration は model の入力であり、宣言だけで Preview Host が利用可能にはなりません。Standalone source generation は静的 SwiftUI subset を扱い、未対応 semantics を error として報告します。Repository Asset は content-addressed blob として取り込めますが、その blob の Native Preview 描画は未実装です。

Spacing Token は GUI と CLI から作成・参照・Stack spacing / container padding へ指定できます。Canvas と macOS Native Preview は alias を解決して同じ値を適用します。その他の Token kind の解決と Inspector は未実装です。

`bash scripts/check.sh` は実装済み契約を検証します。この検証だけでは Native Preview parity、次の format change に対する migration safety、production integration の品質は証明できません。これらは [Technical Spikes](spikes.md) に紐づく実験で測定します。

`hamii query components` の鮮度判定は現在 Document revision のみです。Canonical JSON の外部編集で revision が変わらない場合、query が古い結果を返すことを [Index Drift Spike](../adr/index-consistency/spikes/index-drift/SPIKE.md) で再現しています。現在の信頼できる検索手順は外部変更後に `hamii index rebuild` を実行することです。
