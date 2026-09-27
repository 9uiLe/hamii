# CAS publication and internal process stops

## Related Decision

[Validated merge candidate publication](../../ADR.md)

## Hypothesis

Immutable validated candidate と durable pending gate の下で source ref を expected OID から candidate OID へ CAS 更新すれば、ref 更新を Canonical publication の commit point として扱え、SIGKILL 後は old / candidate / unknown の分類で fail closed に回復できる可能性がある。Index は Canonical とは別に再生成・公開する。

## Questions

- Expected source OID の不一致を CAS が拒否するか。Candidate OID を保持できるか。
- Git ref update の直前・直後、worktree materialization 中、Canonical validation 中、SQLite generation build / commit 中、Index publication 中、pending gate clear 中に SIGKILL すると、Git / Canonical / Index / gate は何を残すか。
- Recovery を繰り返しても既知 old / candidate state に収束するか。Ref が neither の場合は Unknown のまま拒否できるか。
- Candidate build を source lock 外で行い、publication 中の reader を遮断できるか。

## Prototype Scope

Disposable Git repository、独立 OS process、実 Canonical files / CLI validation / SQLite を使う。Immutable candidate OID、source / target OID、Canonical identity、candidate Index identity を記録する。Fault injection は phase 境界でなく操作内部に置き、writer を SIGKILL して別 process の reader と recovery を観測する。Git ref CAS と worktree materialization を別操作にする。

## Out of Scope

Production publisher、arbitrary external writer の保証、Git / SQLite の単一 transaction、fsync / power-loss durability、一般 IndexGeneration architecture。

## Measurements

停止地点ごとの ref OID、working tree identity、pending、published Index identity、reader result、recovery result。Candidate build / publication / recovery の p50・p95 と処理内訳。Prototype の値を production performance とみなさない。

## Success Criteria

Ref old は old へ abort、ref candidate は candidate へ roll-forward、neither は fail closed。Pending の間に Query / mutation が中間 Canonical / Index を使わない。Index failure は Canonical を巻き戻さず、rebuild 後にのみ検索再開。Recovery の再実行で state が変わらない。

## Failure Criteria

Old / candidate 以外の ref から自動 Ready、半 materialized Canonical の利用、future / mixed Index の利用、古い client token の再受理、未検証 candidate の公開。

## Result

**Confirmed in the disposable prototype:** [probe.py](artifacts/probe.py) を実行し、12 停止地点で writer OS process を SIGKILL した。`preRef` と Git `reference-transaction` hook の `refPrepared` では source ref / Canonical bytes とも旧状態で、後者には `.git/refs/heads/<branch>.lock` が残った。Hook の `refCommitted` と `postRef` では ref が candidate OID、Canonical bytes が旧状態だった。`materializing` は Git `read-tree --reset -u` の test-only smudge filter 内で停止し、candidate ref と candidate Canonical bytes が見えた一方、非 Canonical sentinel は未 materialize、`.git/index.lock` が存在した。単一 pending record は CLI gate と兼用し、これらの中間状態を拒否した。Recovery は停止した Git process を確認してから残存 Git lock file を試作内で除去し、candidate commit から再 materialize した。`validating`、SQLite transaction 内の `sqliteBuild`、SQLite commit 直後の `sqliteCommitted`、Index file replace の直前 / 直後、gate unlink の直前 / 直後も記録した。Gate が残る11地点では Query と mutation を拒否し、gate unlink 後のみ Query が current を返した。Recovery 再実行は `alreadyReady` だった。旧 ClientPrecondition での実 mutation は conflict になり、other branch HEAD は維持された。各地点の ref、Canonical identity、pending phase、Index temp file、結果は [result.json](artifacts/result.json) にある。

**CAS / unknown:** `git update-ref` の expected old OID を意図的に誤ると update は拒否され、source ref は変わらなかった。Pending record の old / candidate 以外へ ref を変更した試験では recovery は `unknownRejected`、gate は残り、Query は `transitionPending` だった。

**Index failure:** ref と Canonical bytes が candidate に進んだ後、候補 Index file を削除した。Recovery は完了せず、Canonical は candidate のまま、Query は `transitionPending`。同一 candidate Canonical identity から Index を再生成し、新しい試作用 Index generation identity と hash を pending record に記録して再試行すると、Query は current に戻った。Canonical rollback は使わなかった。

**Measured, prototype only:** macOS 27.0 / Apple M1 Pro、Git 2.52.0、Python 3.14.6 / SQLite 3.54.0、Swift 6.4 / hamii 0.1.0。小規模 disposable project 7 runs の p50 / p95 は、scenario setup（project 初期化、branches、candidate merge、CLI validation / Index、test sentinel commit を含む）が 3,541.184 / 3,549.700 ms、source publication worker が 85.300 / 99.287 ms、Ready 後の初回 CLI Query が 352.019 / 358.147 ms。12 停止地点の recovery p50 / p95 は 38.195 / 44.942 ms。n=7 / n=12 の探索値であり、production latency、large-project scaling、Product SLA ではない。

**Inferred:** immutable candidate OID と CAS を Canonical commit point とし、単一の pending record を CLI gate と兼ねる案は、今回の SIGKILL interleaving を old / candidate / unknown に分類できた。SQLite failure のために Canonical を巻き戻す必要は見られなかった。`refCommitted` と materialization 中に ref / working tree が一致しない実例があるため、gate は ref CAS より前に必要である。

**Unknown / not implemented:** record の fsync / power-loss durability、production `CanonicalSnapshot` identity、production `IndexGenerationID` と source identity の結合、候補 commit / Index の長期保持、production publisher、一般の Index generation atomic switch、同時 read connection と file replace、large project、別 volume、非協調 writer。`os.replace` と `unlink` syscall の内部で deterministic に停止したわけではなく、その直前・直後を測った。Canonical validation 停止は試作用 JSON / identity verification の内部であり、production validator 内部の停止ではない。`read-tree` 中は Canonical bytes 自体の partial snapshot を観測しておらず、非 Canonical sentinel と Git index lock から未完了 materialization を確認した。Candidate Index の再生成は試作の候補 worktree からであり、production Index recovery の完成証明ではない。Power loss は別 ADR。Source lock 内から source CLI validation / rebuild を再入呼び出しすると lock 待ちになるため、production orchestration はこの呼び出し構造を避ける必要がある。

## Conclusion

CAS + pending gate + candidate roll-forward は検証した process crash ordering では有力。Production Snapshot / generation binding、durable pending、Index publication、recovery が未検証のため方式は未決定。ADR は `Spike Required`。

## Artifacts

[Probe](artifacts/probe.py)、[Git reference transaction pause hook](artifacts/ref_hook.py)、[Git smudge pause filter](artifacts/pause_filter.py)、[Result](artifacts/result.json)。
