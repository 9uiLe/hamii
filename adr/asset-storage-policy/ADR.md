# Pending: Asset の Git/LFS 閾値と remote policy

- **Status:** 未確定 / Needs Benchmark
- **Decision needed:** どの binary を通常 Git と LFS に分け、remote cache と generated asset の採用をどう制御するか。
- **Current constraint:** canonical Asset ID と content hash を分離。derived thumbnail/cache は Git に入れない。runtime-bound asset は binding metadata のみ。
- **Options:** size threshold、type-specific threshold、project policy。LFS object 欠落時は preflight failure。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** policy defaults と asset engine/docs/validation が決まったら削除する。
