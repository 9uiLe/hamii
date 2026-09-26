# hamii

hamii は、Human と AI が同じ Native-semantic UI Model を編集し、Canvas、Native Preview、standalone code generation、既存 product repository への integration をつなぐ macOS アプリケーションの設計プロジェクトです。

**現在の状態:** アプリケーション実装はまだありません。この repository は最終設計基準と、実装前に検証すべき実験計画を収録します。Native Preview の性能や production code との一致は未検証です。

## 読む順序

1. [Product & System Architecture](docs/final-architecture.md) — 36 節の現行設計基準
2. [ADR / Spike workflow](docs/adr-workflow.md) — Human と AI に共通の開発ルール
3. [未解決 ADR](adr/) — 各ディレクトリの `ADR.md` と必要な `spikes/<name>/SPIKE.md`
4. [Technical Spikes](docs/spikes.md) — 検証計画の一覧

## 基本境界

```text
Human / AI → 共通 Authoring Policy → Current IR
                                    ├→ Canvas / Native Preview
                                    ├→ Deterministic Generator
                                    └→ Integration Contract + AI → Product Repository

Git Current Format = 正本 / SQLite = 再構築可能な検索 index
Old Format → isolated Migration → Current Format → Core
```

[Native UI の一次資料調査](research/native-platforms.md)・[Preview Runtime 調査](research/preview-runtime.md)・[既存製品調査](research/existing-products.md) は背景資料です。旧設計と解決済み判断は Git history にあります。
