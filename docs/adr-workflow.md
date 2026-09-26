# ADR / Spike workflow

`adr/` は **未解決の設計判断・未検証の技術的疑問・未対応の architecture concern の作業キュー**。完成済み判断のアーカイブは Git history であり、Current Working Tree に保持しない。理想状態は `.gitkeep` 以外がないこと。件数を減らすために未解決 ADR を削除してはならない。

## 作成する条件

Architecture decision が必要、意味のある技術的不確実性がある、破壊的・戻しにくい選択がある、または判断前に prototype/benchmark が必要な場合だけ ADR を作る。通常の実装タスク・bug は issue/task とする。1 ADR に1つの明確な Decision Boundary を置く。Spike の結果から独立して判断できる疑問は別 ADR に分割する。複数の Spike が同じ判断の Evidence なら同じ ADR に置く。短い kebab-case の directory 名を使い、連番を正本にしない。

```text
adr/<decision-name>/
├── ADR.md          # 必須
├── spikes/                             # 実験が必要な場合のみ
│   └── <spike-name>/
│       ├── SPIKE.md
│       └── artifacts/                   # Spike 固有の成果物のみ
└── artifacts/                           # ADR 全体の成果物のみ
```

## ADR.md

`Context`、`Decision to Make`、`Constraints`、`Options`、`Current Hypothesis`、`Unknowns`、`Required Evidence`、`Decision Criteria`、`Status` を記載する。仮説を確定判断のように書かない。Status は `Open`、`Researching`、`Spike Required`、`Ready for Decision`、`Implementation Required`。判断が済んでも実装・検証が未完なら `Implementation Required` にする。一部だけ終わった場合は未解決範囲を明確にして残すか、独立した ADR に分割する。

## SPIKE.md と artifacts/

Spike は architecture 仮説を小さく安価に検証する。`Related Decision`、`Hypothesis`、`Questions`、`Prototype Scope`、`Out of Scope`、`Measurements`、`Success Criteria`、`Failure Criteria`、`Result`、`Conclusion`、`Artifacts` を記載する。実施前に合否基準と対象環境を固定する。結果には観測値、失敗、結論、判断への影響を記す。Prototype code は production 品質を前提にしないが、結果を歪める shortcut は使わない。採用時も validated knowledge を基に production 品質で実装する。

必要なときだけ `spikes/<name>/artifacts/` を作り、その Spike 固有の benchmark、画像、fixtures、試作 code、比較データ、図、logs を保存する。ADR 全体に属する成果物のみ ADR 直下の `artifacts/` に置く。ADR 直下に `SPIKE.md` は置かない。不要な生成物や巨大な build artifacts は commit しない。現在の `SPIKE.md` で Result/Conclusion が未実施なら、成果物を捏造しない。

## Lifecycle と commit 順

```text
問題発見 → ADR 作成 → Research → 必要なら Spike → 判断
        → 判断と結果を commit → 実装 → 検証 → ADR directory 削除 → 削除を commit
```

削除条件は次の **すべて**: 判断済み、必要な調査完了、必要な Spike 完了、必要な実装完了、必要な検証完了、未解決 follow-up なし、判断と結果が削除前の Git commit に存在する。削除前に現行のルールを code/schema/validation/config/tests/docs へ移す。`ADR 作成→調査→実装→削除→1 commit` は禁止。

最低限、Commit A に ADR/Research/Spike Result/Decision、Commit B 以降に implementation、さらに後の Commit C 以降に ADR deletion を置く。PR は分割を推奨する。実装と削除を同じ PR に含める場合も、先行 PR または commit に ADR と結果が残り、実装 commit より後の commit で削除する。

## Current documentation and AI context

Current Code と [Current Architecture](final-architecture.md) は ADR を読まずに理解できる状態にする。Production code が `adr/` に build/runtime dependency を持ってはならない。通常の実装・refactor では関連する現在の ADR だけを読む。Git history の削除済み ADR は歴史的判断を確認する場合だけ読む。
