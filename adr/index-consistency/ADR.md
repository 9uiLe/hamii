# Pending: Local Query Index の鮮度判定

- **Status:** 未確定 / Needs Benchmark
- **Decision needed:** Git pull、外部 edit、未commit mutation、branch switch に対する changed-entity detection と index revision protocol。
- **Current constraint:** SQLite は disposable。stale query result を current と表示しない。
- **Options:** filesystem watcher + fingerprint、Git diff + working-tree fingerprint、full scan fallback。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** freshness invariant、rebuild policy、Query API revision を docs/code に反映して削除する。
