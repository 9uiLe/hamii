# Pending: Capability の契約粒度

- **Status:** 未確定 / Needs Validation
- **Decision needed:** `feature/property/target/runtime version` のどの粒度で Exact、Portable、Approximate 等を宣言し、loss を block するか。
- **Current constraint:** Unsupported を黙って近似しない。Canvas、Host、Generator、AI は同じ判定を使う。
- **Options:** node 単位、property 単位、semantic contract 単位。Navigation/Toolbar/Remote Asset は複合 capability が必要。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** registry schema、diagnostic、target matrix が docs/実装に載ったら削除する。
