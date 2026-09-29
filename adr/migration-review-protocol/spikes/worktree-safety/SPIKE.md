# Migration worktree safety

## Related Decision

[ADR.md](../../ADR.md) の isolated migration candidate の review/publication workflow。

## Hypothesis

Clean committed source OID から detached worktree で candidate を作り、target-format validation と fresh Index rebuild を経て immutable candidate commit を保持すれば、Human は exact source/candidate OID を review できる。受理後に同じ worktree coordination boundary 内で pending gate と expected-source-OID ref CAS を使い、停止後も old / candidate / neither を区別して fail closed に収束できる可能性がある。未検証の仮説であり、既存 `ValidatedMergePublisher` は historical source を読む orchestration として流用しない。

## Questions

Dirty tracked / untracked source を除外せず拒否できるか。Candidate tree は同じ Canonical bytes から決定的に作れ、reviewed candidate OID を保持できるか。Source が review 後に動いた場合に CAS が確実に拒否するか。Pending 中に通常 access が閉じ、ref CAS 前後と Index failure 後の recovery が元データを失わず old / candidate / unknown へ分類できるか。必要 asset/object 不足や semantic validation failure で review-ready に昇格しないか。

## Prototype Scope

- Test-only orchestration を `Tests/` に置く。既存 `HamiiMigrationBoundarySpike` の raw v1→test-only v2 edge を利用し、Current Format v1 の production gate は変更しない。Target-v2 semantic oracle は外側の test harness の adapter とし、production v2 validation の証明と呼ばない。
- Source Git ref/OID/tree、format version、candidate commit/tree OID、edge path/classification、diff、validation、fresh Index result を review report に記録する。Candidate は source OID を parent に持つ1 commit とし、検証成功後だけ retention ref で保持する。Rerun の決定性は candidate **tree bytes/OID** で比較し、author/time に依存する commit OID の一致は要求しない。
- Source worktree は review accept 前に変更しない。Dirty tracked / untracked canonical-looking file は migration start を拒否し、stash や auto commit はしない。Review reject は source 不変、accept は reviewed exact candidate OID のみを publish 可能とする。Candidate の再編集は新 OID / 再 review を要する。
- Test-only pending record は publication ID、source ref、expected source OID、candidate OID/tree OID、retention ref、source/target format version、phase を保持する。Same worktree lock / client observation invalidation / pending-gate semantics を模擬する。Production `WorktreeCoordinator` API や merge pending record は変更・流用しない。
- Publication commit point 候補は expected source OID→reviewed candidate OID の `git update-ref` CAS。Source ref が old なら abort、candidate なら materialize・target validation・fresh Index rebuild で roll-forward、neither なら Unknown / gate 維持。Cross-format `git merge` は使わない。Index failure では Canonical ref を rollback しない。
- Helper OS process を止める case は transform 中、pending 後 CAS 前、CAS 後 materialization 前、Index publish 後 gate release 前を優先する。SIGKILL 等は process-stop evidence とし、power-loss/fsync evidence と呼ばない。
- Cleanup success/failure、validation failure、required asset/object unavailable、classification `potentiallyLossy` / `manual` を negative control とする。Actual Git LFS transport はこの Decision の検証に含めない。

## Out of Scope

Production Format v2 schema / ordered effects / v1→v2 edge、migration executor/CLI、`WorktreeCoordinator` production refactor、`ValidatedMergePublisher` の historical 対応、ambiguous value 解決 UI、LFS transfer、power-loss durability、一般的 Git collaboration model。Prototype の index/adapter を production validation とみなさない。

## Measurements

`artifacts/review-publication-matrix.json` の各 case に、少なくとも `case`、`sourceOID`、`sourceTreeOID`、`candidateOID`、`candidateTreeOID`、`sourceDirty`、`candidateValidated`、`reviewDecision`、`sourceOIDAtPublish`、`casResult`、`phaseAtStop`、`recoveryResult`、`sourceBytesPreserved`、`worktreeClean`、`freshIndexResult`、`gateReleased` を記録する。`artifacts/workflow-comparison.md` には isolated worktree / mutable branch / source-in-place の correctness と保守負担、exact diff (`git diff --name-status` / `--stat`) と expected/unexpected changed paths、source/candidate parent、retention ref と object availability、制約と未検証事項を記録する。時間値はこの Decision の合否条件ではない。

Mandatory cases: clean reject、clean accept/publish、dirty tracked、dirty untracked、candidate validation failure、review 後 source move/CAS reject、before-CAS stop、after-CAS before materialization stop、after materialization/current validation stop、Index failure 後 pending recovery、old/candidate/neither recovery、required object unavailable、review 後 candidate change。Process-stop 4地点と cleanup は実施条件・未実施を明記する。

## Success Criteria

- Review accept 前に source worktree/ref と published Index は不変。Dirty user edit を黙って除外しない。
- Candidate は exact source OID と parent で結び、validated target candidate tree は同入力で決定的。Review は immutable candidate OID と exact diff に対して行い、retention ref は review 中に変わらない。
- Candidate validation / fresh Index は review-ready より前。Unknown/required object 不足、ambiguous classification、予期しない changed path は publish しない。
- Source move 後の CAS は拒否し、cross-format merge をしない。Client observation は commit point 前に失効し、pending gate 中は通常 access を拒否する。
- Old/candidate/neither recovery は deterministic / fail closed。Post-CAS failure は candidate へ roll-forwardし、fresh Index と source binding を検証してから gate を最後に解除する。
- Process-stop の主張は SIGKILL の範囲に限定する。`HamiiMigrations` は Core/Format/Index に依存せず、production Format は v1 のまま。
- Focused tests、full gate、Release `HamiiMigrations` build、Evidence の exact-SHA CI が成功する。

## Failure Criteria

Review accept 前に source を変更する、dirty user edit を auto stash/commit する、historical/current 間の semantic/text merge が必要、source OID または reviewed candidate OID を固定できない、source move 後も publish が成功する、post-CAS recovery が historical への自動 rollback を要する、worktree lock/epoch の production owner を複製する、または merge publisher/Core に historical branch を追加する場合は Decision へ進まない。LFS transport 不足のみでは generic unavailable-object の fail-closed が示せれば isolation Decision を止めず、範囲を限定して記録する。Ambiguous case は [migration-ambiguity-resolution](../../../migration-ambiguity-resolution/ADR.md) に渡す。

## Result

Test-only orchestration は Starter の clean Git source commit から detached worktree を作り、raw v1→test-only v2→synthetic v3 edge、各中間の semantic oracle、fresh LocalIndex rebuild、candidate commit と retention ref、exact diff を生成した。21 case の source/candidate OID、tree OID、phase、CAS、gate、recovery は [review-publication-matrix.json](artifacts/review-publication-matrix.json)。同じ source tree から同じ candidate tree が得られ、review は source/candidate の exact OID pair に固定された。Commit OID の再実行一致は要求・主張しない。

Dirty tracked/untracked は開始拒否。Token shard 欠落は `token.missing`、Repository asset blob 欠落は `asset.integrity` で review-ready 前に拒否。Review reject は source を変更せず候補を明示 cleanup。Review 後に candidate worktree を編集しても retention ref は元 OID を保ち、新 OID の publish は拒否。Source が動いた場合は preflight 拒否し、pending 後の raw ref 変更では expected-OID CAS 自体が拒否した。別 detached worktree で text merge が成功する negative control でも migration publisher は cross-format merge を使わなかった。

Pending 中の in-process failure 5地点と、別 OS process の SIGKILL 5地点（transform、pending、refPublished、currentValidated、indexPublished）を検証。Reader は writer 生存中の lock を越えず、kill 後に transform では Ready、publication stop では pending を観測。Old ref は old state 維持、candidate ref は validation / fresh Index の再実行後に roll-forward、neither ref は pending を維持。Index rebuild 注入失敗では candidate ref を rollback しなかった。Focused run は8 tests（worker entry point 2 skip）、失敗0、73.939秒。これは単一 run の所要時間で性能 benchmark ではない。[workflow-comparison.md](artifacts/workflow-comparison.md) に候補比較、exact diff、証明範囲を記録した。

Full gate は 14 checks 成功、Swift test 251 実行・失敗0・skip 58、506.224秒。Release `HamiiMigrations` build は成功。Evidence commit `328bee98bd794899ecd879bc6d8b29a78fa82792` の [exact-SHA CI](https://github.com/9uiLe/hamii/actions/runs/36503082850) は成功。

初回の cleanup 試行では macOS の `/var` と `/private/var` の同一 main worktree path を別物と誤認した。実体 path の正規化へ修正し、最終 focused run は成功。Source-in-place cleanup は行っていない。

## Conclusion

Clean committed source から isolated candidate を作り、target validation と fresh Index check を先行させ、exact OID review 後に ref CAS で公開する workflow は、この test-only fixture と停止点で成立した。Pending gate と old/candidate/neither recovery は source の無断変更や historical ref への自動 rollback を必要としなかった。これは production migration executor、v2/v3 reader、production Index generation publication、Git LFS transfer、power-loss durability の完成証明ではない。ADR Decision は full gate・Release build・exact-SHA CI の結果確認後、別 commit で判断する。

## Artifacts

- [review-publication-matrix.json](artifacts/review-publication-matrix.json)
- [workflow-comparison.md](artifacts/workflow-comparison.md)
