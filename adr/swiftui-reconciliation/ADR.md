# Pending: SwiftUI Host reconciliation and state identity

- **Status:** 未確定 / Needs Prototype
- **Decision needed:** 値 patch、子移動、node kind 変更、Screen root 変更の各操作で、どの subtree を再構築し、どの state を保持できるか。
- **Current constraint:** supported edit は暗黙 compile を起動しない。保持できない focus/scroll/@State は明示診断する。
- **Options:** stable ID + recursive renderer、local snapshot partition、root replacement。`AnyView` の使用範囲も比較する。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** reconciliation class と reset diagnostic を docs/Host 実装に固定し、この file を削除する。
