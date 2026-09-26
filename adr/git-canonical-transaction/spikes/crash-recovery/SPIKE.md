# Crash recovery transaction

## Related Decision

[ADR.md](../../ADR.md) の「multi-file save の commit/recover protocol」を判断するための Evidence。

## Hypothesis

staging + manifest/journal で torn canonical graph を防げる。

## Questions

各保存段階で kill しても complete revision に戻るか。外部 edit と競合時に誤上書きしないか。

## Prototype Scope

3 個の JSON shard（旧版では `a → b`、新版では `a → c`）と revision manifest の保存を各段階で停止し、再起動後の recovery を試す。各 file と journal directory を同期し、同一 directory 内で rename する。

## Out of Scope

shard 粒度の最適化、semantic merge engine、SQLite 正本化、停電・ストレージ障害、Git による並行書込、大規模 project の性能。試作 code を production code として扱わない。

## Measurements

recovered revision、参照の完全性、recovery の再実行性、外部編集の保持、プロセス起動を含む save/reopen 時間。実行環境は macOS 26.2 / APFS Data volume。`python3 adr/git-canonical-transaction/spikes/crash-recovery/artifacts/probe.py` で 8 停止位置を各 5 回実行した。試作は各 file と directory に `fsync` を呼ぶが、write 回数と純粋な保存処理の latency は計測していない。

## Success Criteria

complete old/new revision に復旧し、reference validation が通る。

## Failure Criteria

torn graph が正本として開かれる、または再実行で異なる結果になる。

## Result

40/40 回、recovery 後の shard と manifest が完全な旧版または新版と一致し、2 回目の recovery でも結果は変わらなかった。manifest の更新前の停止では旧版、更新後では新版となった。異なる内容の外部編集を加えた試行では競合を検出し、外部 bytes と journal を保持した。プロセス起動を含む総時間は p50 38.554 ms、p95 43.492 ms。この値は production 保存 latency を表さない。

Apple の [File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/TechniquesforReadingandWritingCustomFiles/TechniquesforReadingandWritingCustomFiles.html) は write 成功だけでは永続化を保証せず、必要に応じて `fsync` などを使うと説明する。[APFS Features](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/Features/Features.html) は copy-on-write metadata と atomic safe-save を説明する。今回の試行はプロセス停止の検証であり、停電後の durability を実証していない。

## Conclusion

staging、旧新 snapshot、manifest revision を使う journal は、試したプロセス停止位置では torn graph を防げる。この Evidence に基づきプロセス停止時の復旧 protocol を採用した。同時 Git 操作と停電後の durability は独立した ADR の未解決範囲とする。試作 code は production 実装へ流用しない。

## Artifacts

- [probe.py](artifacts/probe.py): 再実行可能な使い捨て試作。
- [result.json](artifacts/result.json): 40 回分の結果。
