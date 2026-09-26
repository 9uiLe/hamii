# Pending: Migration の review と ambiguous value 解決

- **Status:** 未確定 / Needs Prototype
- **Decision needed:** dirty tree、manual/lossy edge、Git worktree/branch、review commit を macOS UI でどう扱うか。
- **Current constraint:** Core は Current Format のみ。元 repo は preflight/review 前に変えない。曖昧な color→token は推測しない。
- **Options:** temp worktree + report、snapshot/commit choice、manual resolution editor。cross-version branch merge は拒否する。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** Migration Coordinator、UI、report format、docs に手順が揃ったら削除する。
