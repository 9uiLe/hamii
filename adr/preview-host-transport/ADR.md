# Pending: Native Preview Host transport

- **Status:** 未確定 / Needs Prototype
- **Decision needed:** macOS Editor と iOS Simulator Host の双方向通信、frame capture、input forwarding にどの transport と session protocol を使うか。
- **Current constraint:** Host は `LoadSnapshot`、`ApplyPatch(baseRev,newRev)`、`Ack`、再接続時の full snapshot を扱う。Simulator.app の Canvas 埋込を前提にしない。
- **Options:** local socket、Network framework connection、別の supported IPC/stream。frame は image stream と native surface bridge を比較する。
- **Validation:** [SPIKE.md](SPIKE.md) に検証手順と成果物を記録する。
- **Resolve when:** transport と protocol version、障害時の復旧、frame/input の実装を docs と Host code に反映したらこの file を削除する。
