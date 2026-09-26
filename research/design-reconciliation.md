# 旧案と現行設計の照合

2026-09-26。旧案は [product-architecture.md](../docs/product-architecture.md)、現行は [final-architecture.md](../docs/final-architecture.md)。下表の外部技術に関する事実は一次資料に基づき、hamii の採否は設計判断であり実証ではない。

| 旧案・以前の final draft | 現行判断 | 理由 / 検証 |
|---|---|---|
| `.hamii` package の JSON shards を主な正本とする | Git repository の Current Canonical Format を正本にする | 共同編集、branch、review を基本 workflow にする。atomic save と file 粒度は Spike 08。 |
| Page が screen/export の主な整理単位 | Page は自由な Canvas 整理。ScreenDefinition と AppSurface は ID で参照 | Page と ownership を分離。Scope は別 tree。 |
| Component は主に Definition/Instance | ownerScope、ancestor dependency、availability、promotion、variant API を追加 | Product architecture を機械的に検証。Spike 05/06。 |
| AI は summary/detail/diff API | Agent Harness、共通 Authoring Harness、Scope-aware retrieval と mutation | Prompt で architecture rule を強制しない。Spike 07/13。 |
| IR→Host/Generator が主な出口 | Integration Contract + Integration Harness + AI を別出口にする | Product repository 固有 architecture を IR に入れない。Spike 14。 |
| Derived index を想定するが永続正本境界が曖昧 | SQLite は完全 disposable。Git files から再生成 | Index drift/破損は rebuild。Spike 09。 |
| 旧 format の扱いが未定 | historical parser/migrator を Core 外に隔離 | Core は Current Format のみ。Spike 10/11。 |
| SwiftUI Host first、UIKit/Compose separate | 維持。ただし UIKit は Spike 後に MVP 必須判定、Compose Android は早期 IR validation、CMP Host は Later | 二つの Host を MVP の前提にして検証を遅らせない。 |
| `Component Build` を軽い段階として見せる余地 | build required と表示し relink/install を実測 | custom source 更新に部分 build が有効とは未実証。 |

## 外部事実と設計上の推論

- **事実:** SwiftUI は state changes に応じて view を更新するが、identity が変わると state が置換され得る。[Apple state](https://developer.apple.com/documentation/swiftui/managing-user-interface-state/)、[WWDC21](https://developer.apple.com/videos/play/wwdc2021/10022/)。**推論:** hamii Host は値 patch と構造 reconcile を分け、reset を診断する。
- **事実:** UIKit `UINavigationController` は navigation bar を管理する。[Apple](https://developer.apple.com/documentation/uikit/uinavigationcontroller)。**推論:** hamii は bar を座標 Layer にしない。
- **事実:** Compose UI は state 変化から recomposition される。[Google](https://developer.android.com/develop/ui/compose/lifecycle)。**推論:** Compose Host は observable model に patch を入れる。
- **事実:** Git LFS 利用者以外には pointer のみが届く場合がある。[GitHub](https://docs.github.com/en/repositories/working-with-files/managing-large-files/collaboration-with-git-large-file-storage)。**推論:** asset migration/open の preflight で object availability を検査する。

## 未検証

Preview Host の transport、patch latency、state retention、Host と production の parity、Git multi-file save recovery、SQLite incremental index、migration UX、AI integration 成功率は [Technical Spikes](../docs/spikes.md) で判定する。
