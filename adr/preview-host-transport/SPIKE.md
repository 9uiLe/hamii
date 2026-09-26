# Spike: Native Preview Host transport

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 04 Patch Runtime
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

常駐 iOS Simulator Host は順序付き patch と frame/input を安全に往復できる。

## Method

macOS coordinator と iOS Host を実装し、初回 snapshot、連続 patch、切断・再接続、schema mismatch、複数 Surface、入力転送、frame capture を実行する。

## Evidence to collect

revision と frame の一致、patch→frame p50/p95/p99、再接続成功率、CPU/メモリ、古い frame の表示を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

欠番後に full snapshot で収束し、古い frame が current と表示されず、通常編集で compile が発生しない。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
