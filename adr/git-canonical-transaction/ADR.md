# Pending: Git Canonical Format の分割粒度と保存 transaction

- **Status:** 未確定 / Needs Benchmark
- **Decision needed:** Layer ごと/部分 tree ごと/page ごとの shard 粒度、および multi-file save の atomicity/recovery protocol。
- **Current constraint:** Git の canonical files だけで復元可能。stable ID path、deterministic serialization、部分書込の正本化を防ぐ。
- **Options:** entity-per-file + manifest revision、page shard + journal、別の atomic staging protocol。SQLite authoritative は現方針に反するため失敗時の比較対象。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** format layout、save/recovery implementation、validation を docs/code に固定して削除する。
