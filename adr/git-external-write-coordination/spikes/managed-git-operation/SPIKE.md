# hamii-managed Git operation と writer boundary

## Related Decision

[External Git Write ADR](../../ADR.md) の正式な Canonical collaboration / writer model。Index の safe fast path はここで定める writer guarantee を入力条件にする。

## Hypothesis

**Tentative:** hamii が管理する Git operation は Canonical save と同じ worktree lock の下で pending → Canonical state change → generation finalize を行い、reader は完了まで待てる。直接実行する Git CLI は lock / generation を迂回する。

## Questions

- raw `git switch` は現行 `.hamii/write.lock` を尊重するか。
- 試験用 wrapper で reader と branch switch を同じ lock に入れると中間 branch を読まずに済むか。
- production の journal / generation / Index / session にどう統合するか。

## Prototype Scope

使い捨て Git Repository に Canonical Data が異なる 2 branch を作る。親 process が現行 `.hamii/write.lock` を保持し、別 OS process の `hamii inspect` を待たせる。その間に raw Git switch と、test-only pending / generation 記録付きの coordinated switch をそれぞれ実行する。

## Out of Scope

Production Git operation adapter、全 Git command の網羅、非協調 writer の完全検知、正式な `CanonicalGeneration` schema / atomic publication。

## Measurements

lock 保持中の reader wait、raw switch 完了、試験用 generation の変化、lock 解放後に reader が見た branch。switch 時間は一回の局所値のみ記録し、性能の比較根拠としない。

## Success Criteria

raw Git と hamii lock の保証境界を実測で識別する。試験用 coordinated switch では reader が lock 解放まで待ち、最終 branch を読む。

## Failure Criteria

lock を無視する Git を hamii-managed operation と誤分類する、または読者が試験用協調 switch の途中状態を読む。

## Result

**Confirmed, one disposable Repository, macOS 26.2 / Git 2.52.0:** 親 process が `.hamii/write.lock` を保持し、別 OS process の `hamii inspect` が完了しない間、raw `git switch` は同じ lock の保持中に成功した。試験用 generation は 0 のままで、reader は lock 解放後に切替先 branch を読んだ。これは raw Git が lock / generation を迂回できる具体的反例である。reader の lock 取得地点の marker はこの probe に含まれず、厳密な lock 競合の合図は [Shared Generation process-stop matrix](../../../index-consistency/spikes/shared-worktree-generation/SPIKE.md) の別試験を参照する。

**Confirmed for test-only wrapper:** 親 process が同じ lock を保持し、試験用 generation を `pending` にして `git switch` を実行し、世代を 1 に進めてから解放した。reader は解放前に完了せず、解放後に最終 branch を読んだ。**Not implemented:** production の managed Git adapter、journal と generation の結合、Index publish、client session invalidation。150 ms の wait barrier と 1 回の switch だけを測った。これを production concurrency guarantee とは扱わない。

## Conclusion

raw Git は現行 hamii lock の writer domain に属さない。Product Contract は [External Git Write ADR](../../ADR.md) に決定した。Git operation を hamii-managed と呼ぶには lock / generation / recovery / validation への production 統合が必要。Client session precondition は独立 ADR、Index publication は Index ADR が扱う。

## Artifacts

- [probe.py](artifacts/probe.py): 一時 Repository の実プロセス probe。
- [result.json](artifacts/result.json): raw / coordinated switch の観測結果。
