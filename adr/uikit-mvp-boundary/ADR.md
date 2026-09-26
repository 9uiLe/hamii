# Pending: UIKit Preview の MVP inclusion

- **Status:** 未確定 / Needs Prototype
- **Decision needed:** UIKit Host を MVP 必須 gate に含めるか、SwiftUI MVP 後の target とするか。
- **Current constraint:** IR と Capability は UIKit を初期から区別する。UIKit の controller/navigation を rectangle に近似しない。
- **Options:** SwiftUI と同時提供、UIKit は limited alpha、UIKit は Phase 5。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** MVP gate と target coverage を docs に更新し、Host code/テストが対応したら削除する。
