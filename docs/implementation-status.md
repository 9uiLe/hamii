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

`WorktreeCoordinator` が Canonical save、managed `git switch`、CLI query / rebuild、validated merge publication の同一 lock と pending gate を所有します。`git switch` は client token を開始時に失効させます。`git merge check` は一時 worktree で semantic validation と一時 Index rebuild を行い、source worktree を変更しません。`git merge publish` は検証済み candidate commit を ref CAS で公開し、Canonical 検証と full Index rebuild の後に gate を解除します。`git recover` は中断した managed switch または publication の既知状態だけを回復します。一般の Index generation protocol と停電耐久性は未確定です。

`hamii query components` は Canonical revision の不一致を `staleIndex` として拒否し、結果を返しません。現行計算方式は Git の `assume-unchanged` / `skip-worktree` または filter が Canonical file にある場合も拒否します。外部変更後は `hamii index rebuild` で再構築してください。最初の Git status 後に branch switch が完了する制御された race は、最後に status を再照合して拒否します。任意の同時外部書込への保証はありません。[Low-cost freshness Spike](../adr/index-consistency/spikes/low-cost-freshness/SPIKE.md) の Starter Sample / 40-run 条件では CLI query p95 約 405 ms、5000 Component shard の pilot では mostly-untracked の query 5 回最大値約 474 ms、all-tracked 約 230 ms でした。coordinator 接続を含む現行 end-to-end の再測定は未実施です。自動 full rebuild、増分再索引、任意の Git 同時書込、atomic generation publish は未実装・未検証で、[Index ADR](../adr/index-consistency/ADR.md) の検証対象です。
