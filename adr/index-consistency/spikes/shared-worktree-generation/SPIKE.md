# Shared Worktree Generation の保証境界

## Related Decision

[Index consistency ADR](../../ADR.md) の safe steady-state Query。前提となる同一 worktree の writer contract は [External Git Write ADR](../../../git-external-write-coordination/ADR.md) が決める。`CanonicalSnapshot → CanonicalRevision` の取得保証は [CanonicalSnapshot Spike](../consistent-canonical-snapshot/SPIKE.md) の別論点。

## Hypothesis

**Tentative:** 同一 worktree の **全 writer** が共有 lock / generation protocol に従うなら、永続化した `CanonicalGeneration` と SQLite に同時に保存した `IndexGeneration.sourceCanonicalGeneration` の一致で steady-state Query を許可できる可能性がある。未完了 save を先に `pending` として永続化し、Canonical save 後に世代を進めれば、save と index publish の間で crash しても古い Index を current と扱わずに済む。ただし非協調 writer が直接 Canonical bytes を変えれば generation equality は false current になる。

## Questions

- 全 hamii GUI / CLI / AI writer と協調 Git 操作を、同じ lock / generation 更新へ強制できるか。プロセスや worktree identity をどう扱うか。
- `CanonicalSnapshot` の exact contents から `CanonicalGeneration` を確立し、IndexProjection の入力と SQLite metadata を同じ source に結び付けられるか。
- `pending` 中の停止、journal recovery、index build/validation failure、SQLite commit、process restart、power loss の各順序で何が読み取れるか。
- Generation state の欠損・破損・削除・復元・巻戻し、外部 Git 操作、同一 worktree 非協調 writer をどう `Unknown` / stale へ倒すか。
- 共有 lock と generation read/write の Query p50/p95、save cost、競合時 latency、大規模 Index での throughput はどうか。

## Prototype Scope

使い捨て Git worktree で実 `CanonicalRepository` 2 instance と実 `LocalIndex` を使う。`.hamii/prototype-generation.lock` と fsync + rename で保存する test-only generation record を追加し、`LocalIndex` の既存 `canonicalRevision` metadata に `gen-N` を **試験用 source generation** として格納する。Save、Git branch switch、Query、Index rebuild に同じ prototype lock を使い、`pending` / source mismatch / future index / fresh OS process の制御地点を観察する。非協調 edit の negative control も実行する。

## Out of Scope

Production への generation protocol 導入、`CanonicalRevision` algorithm の採用、真の `CanonicalSnapshot` 取得、`IndexGeneration` ID の追加、任意 external writer の安全性保証、External Git Write ADR の Product Contract 決定。

## Measurements

2 Repository instance、fresh process Query、保存前 pending、保存後 pending、世代進行後かつ Index 公開前、future Index、協調 branch switch、非協調 edit の結果。30 warm Query の p50/p95 と generation record の2回の書込 cost。別 OS process の writer / reader が同じ prototype lock を競合し、4地点で実 `SIGKILL` した際の起動時拒否・journal 回復・同一 source snapshot からの再索引。Power loss と長時間の multi-process contention は別測定とする。

## Success Criteria

**条件付き:** protocol に従う writer だけが存在する間、公開 Index metadata の source generation が共有 Canonical generation と一致するときだけ Query を許可する。Pending / mismatch / unknown は拒否。Canonical save より先に Index N+1 を current として見せない。Restart 後は永続 state だけで同じ条件を再評価できる。保証外の writer を黙って保証内に数えない。

## Failure Criteria

未完了 save 中に旧 Index を current と返す、別 hamii writer の save 後も旧世代を current と返す、future Index を公開する、または外部 writer が protocol を迂回できるのに generation equality を一般的な Canonical freshness proof と主張する。

## Result

**Confirmed for this controlled prototype:** [XCTest](../../../../Tests/HamiiTests/SharedWorktreeGenerationSpikeTests.swift) は別の `CanonicalRepository` instance の save を shared prototype lock 内で実行した。`pending` を先に永続化すると、Canonical save 前と save 後の中断地点を fresh child process が `staleIndex` と判定した。世代を N+1 に進め Index が N のままの地点も拒否。Index metadata を先に `gen-(N+1)` にした future-index negative control も generation mismatch で拒否した。実 `LocalIndex.rebuild` 後は対応する row のみ読み、別 OS process の [reader](artifacts/restart_query_probe.py) も永続 generation / SQLite metadata の一致を読んだ。協調 prototype lock 内の実 Git branch switch は世代を進め、旧 Index を拒否した。

**Measured, one local run:** macOS arm64、Swift 6.4 debug XCTest、1 component の使い捨て Git worktree。30 warm Query（実 `LocalIndex.components` + shared `flock` + generation file read）は p50 **0.114 ms**、p95 **0.137 ms**。`pending` record の fsync + rename + parent fsync は **0.581 ms**、`current` への更新は **0.757 ms**（各1回）。Fresh Python process の Query 内部は **1.80 ms**（1回、process startup は含まない）。これらは小規模・無競合・test-only protocol の値であり、Product SLA や production fast path の性能ではない。[raw result](artifacts/shared-generation-result.json) に測定条件と値を保存した。

**Confirmed counterexample:** `.hamii/prototype-generation.lock` を無視する外部 writer が Component JSON を直接変更すると、共有 generation と Index source generation は一致したままで、prototype Query は旧 row を `current` と返した。したがって shared generation equality は **全 writer が protocol に従うという前提の外では安全な判定ではない**。Filesystem watcher に event が来ないことも positive proof にはできない。

**Confirmed, real process-stop matrix:** [focused XCTest](../../../../Tests/HamiiTests/SharedGenerationCrashSpikeTests.swift) は別 OS process の writer (`xctest`) と reader (`python3`) を同じ test-only lock で競合させ、`pending`、Canonical shard 適用中の `save`、世代確定後、Index 公開後の4地点で writer を `SIGKILL` した。reader は writer lock 中に待ち、起動時 gate を通る reader は kill 後の全地点で `staleIndex` を返した。新 recovery process の最初の `LocalIndex` Query も `staleIndex`。`save` 地点では `.hamii/transaction.ready` が残り、`CanonicalRepository.load` が旧 manifest に沿って rollback し、journal を削除した。他の地点では完全な Canonical state を読んだ。Recovery は lock 下で Canonical bytes の path/bytes digest を Index rebuild 前後で比較し、実 `LocalIndex.rebuild` に同じ load 済み Document を渡した後にのみ Query を再開した。`pending` / `save` は Alpha、世代確定 / Index 公開は Beta を返した。[matrix](artifacts/process-stop-matrix.json) に4ケースの結果を残した。

**Confirmed lock contention and kill ordering:** reader は `flock(LOCK_SH)` の直前に `reader.attempt`、取得直後に `reader.acquired` を書く。4ケースとも attempt marker が存在し、writer 生存中の150 ms は acquired marker がなく、reader process は実行中だった。親 process が writer を `SIGKILL` し、終了理由 `uncaughtSignal` と status 9 を確認した後に acquired marker が現れた。これにより単なる reader 起動時間を lock 待ちと誤認しない。

**Candidate boot transition, test-only:** 新しい reader は `Unknown` から開始し、次の全条件を満たすまで `LocalIndex` Query を拒否する。(1) `CanonicalRepository.load` による journal 回復が完了し、未処理 `transaction.ready` がない。(2) coordinated lock が排除する writer domain 内で取得した Canonical path/bytes set が、再索引前後で同一である。(3) Index の `canonicalRevision` metadata が共有 `CanonicalGeneration` に対応する。(4) 公開済み `IndexGenerationID` が存在し、検証した候補 ID と一致する。試験では Index rows の rebuild 後、test-only generation ID を SQLite に記録し、その後も boot gate が拒否することを確認してから条件を照合して解除した。Snapshot digest の一致だけを multi-file atomicity の証明とは扱わない。一貫性の前提は試験用 coordinated lock と参加 writer の範囲である。

**Negative controls:** 実 Canonical Component JSON を変更して snapshot identity を不一致にした場合、Index source generation が shared generation と異なる場合、generation ID が欠落する場合、journal 未解決の入力は、同じ起動時判定で `KnownCurrent` へ移行しなかった。この判定は test-only であり、production の generation model / boot protocol を確定しない。

**Failure evidence for restart policy:** Index 公開後の地点では、起動時 gate を持たない raw reader は kill 後に generation equality だけを見て `current` を返した。起動時にまず `Unknown` / 検索拒否へ落とすという条件は shared generation equality から自動的には得られない。今回の boot gate は test-only であり、production に実装されていない。

**Blocked / unvalidated:** prototype lock は現行 `.hamii/write.lock` と別であり、実 CLI / GUI や外部 Git を強制的に包まない。4地点では実 OS process を `SIGKILL` したが、power-loss injection ではない。Recovery 時の path/bytes 再読込は coordinated lock 内の fixture に限る証拠であり、非協調 writer 下の atomic Snapshot を証明しない。Test-only generation ID は Index rows の transaction とは別 transaction で書き、外側の lock / boot gate が途中状態を隠した。Production の atomic index generation publication は未実装。`pending` からの一般的な recovery classification、世代 record と CanonicalSnapshot の永続 identity、同時 writer throughput、worktree relocation、record 欠損/破損、SQLite generation ID / rollback、large-project contention は未検証。`LocalIndex` の `canonicalRevision` 列を試験用 generation に流用したことは schema / API 決定ではない。

## Conclusion

Shared generation は、**既知の coordinated writer domain 内**で低 cost な Query を成立させる有力な条件付き仮説になった。External Git Write ADR は同一 worktree の Product Contract を決めたが、この prototype は production が domain を強制できること、Snapshot と generation の binding、crash recovery / power-loss、Index generation publication を証明していない。これらを検証するまで Safe Fast Path は採用しない。Production は現行 `staleIndex` 拒否を維持し、Index ADR は `Spike Required`。

## Artifacts

- [SharedWorktreeGenerationSpikeTests.swift](../../../../Tests/HamiiTests/SharedWorktreeGenerationSpikeTests.swift): 実 CanonicalRepository / LocalIndex と test-only shared protocol。`HAMII_SHARED_GENERATION_SPIKE_RESULT=/tmp/hamii-shared-generation-result.json swift test --filter SharedWorktreeGenerationSpikeTests` で再測定する。
- [restart_query_probe.py](artifacts/restart_query_probe.py): 新 OS process による永続 generation / SQLite metadata の読込。
- [shared-generation-result.json](artifacts/shared-generation-result.json): 1 run の状態・timing・制約。
- [SharedGenerationCrashSpikeTests.swift](../../../../Tests/HamiiTests/SharedGenerationCrashSpikeTests.swift)、[process-stop-matrix.json](artifacts/process-stop-matrix.json): 4 OS-process `SIGKILL` barrier、reader lock 競合、起動時拒否、Canonical journal recovery、再索引。`HAMII_CRASH_SPIKE_MATRIX_RESULT=/tmp/hamii-crash-matrix.json swift test --filter SharedGenerationCrashSpikeTests/testRealProcessStopsAcrossGenerationPhases` で再実行する。
