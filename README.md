# hamii

hamii は、Human と AI が同じ Native-semantic UI Model を編集し、Canvas、Native Preview、standalone code generation、既存 product repository への integration をつなぐ macOS アプリケーションの設計プロジェクトです。

**現在の状態:** アプリケーション実装はまだありません。この repository は最終設計基準と、実装前に検証すべき実験計画を収録します。Native Preview の性能や production code との一致は未検証です。

## 読む順序

1. [Product & System Architecture](docs/final-architecture.md) — 36 節の現行設計基準
2. [確定した設計判断](docs/architecture-decisions.md) — ADR-001〜030
3. [未確定・未対応の判断](adr/) — 各ディレクトリの `ADR.md` と `SPIKE.md` に判断・検証を分ける。解決後は docs/実装に反映してディレクトリを削除し、`.gitkeep` 以外 0 件を目指す
4. [Technical Spikes](docs/spikes.md) — 14 の検証計画と判定条件
5. [旧案との照合](research/design-reconciliation.md) — 変更点と失効した前提

## 基本境界

```text
Human / AI → 共通 Authoring Policy → Current IR
                                    ├→ Canvas / Native Preview
                                    ├→ Deterministic Generator
                                    └→ Integration Contract + AI → Product Repository

Git Current Format = 正本 / SQLite = 再構築可能な検索 index
Old Format → isolated Migration → Current Format → Core
```

[旧 Product Architecture](docs/product-architecture.md) と [Native/Preview の一次資料調査](research/native-platforms.md)・[Preview Runtime 調査](research/preview-runtime.md)・[既存製品調査](research/existing-products.md) は背景資料です。旧 Product Architecture の結論は現行決定ではありません。
