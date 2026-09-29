# Migration の repository isolation / review workflow

## Context

Format migration は repository 全体を変更し、dirty tree や途中失敗で元の作業を失う可能性がある。

## Decision to Make

Historical source commit から migration candidate を隔離して作り、Human が exact source/candidate OID と diff を review した後、source が観測時と同一の場合だけ publish できる workflow をどう構成するか。途中停止・source 変更・validation failure で元の user data を失わず fail closed にできるか。

## Constraints

Core は Current Format のみ。元 tree を review 前に無断変更しない。異なる format version を直接 semantic merge しない。

## Options

temporary worktree + branch、snapshot/commit choice、別の isolated staging。

## Current Hypothesis

解決済み。採用した workflow は以下の Decision に記録する。

## Decision

Migration は clean かつ committed な source worktree の exact source ref/OID から始める。Dirty tracked/untracked Canonical data は開始を拒否し、stash・auto commit・暗黙の snapshot 化をしない。Raw historical edge は source OID に固定した隔離 detached worktree で実行する。各 edge を検証し、target Current Format の parse / schema / semantic validation と fresh Index check が成功した candidate だけを、source OID を唯一の parent とする commit にして retention ref で保持する。Candidate tree bytes/OID の再実行決定性を要求するが、Git commit metadata に依存する candidate commit OID の再実行一致は要求しない。

Human review は `sourceRef`、`sourceOID`、source/target format version、edge path と分類、exact `candidateOID` / tree OID、changed paths、`git diff --name-status` / `--stat`、validation と Index 結果を対象にする。Review acceptance はその具体的 candidate OID のみを authorize する。Candidate を変更した場合は別 OID として再検証・再 review が必要。`potentiallyLossy` / `manual` の分類や必要 asset/object 不足は自動 publish authorization にならない。予期しない changed path を含む candidate は拒否する。

Publication は merge や source worktree 上での変換再実行を行わない。Migration-specific orchestrator が既存の `WorktreeCoordinator` の lock / client observation invalidation を使い、durable pending gate を設定してから `expectedSourceOID → reviewedCandidateOID` の Git ref CAS を行う。CAS 成功を Canonical publication commit point とする。Source OID が動いていれば publish せず、新しい source から candidate を作り直す。CAS 後は candidate を worktree へ materialize し、Current Format と Canonical contents を再検証し、fresh Index generation を publish してから最後に gate を解除する。Index failure を理由に Canonical ref を historical source へ自動 rollback しない。

Recovery は source ref が expected old OID なら old state を維持して abort、candidate OID なら candidate へ roll-forwardして再検証・Index 再構築、どちらでもなければ Unknown として gate を維持する。`ValidatedMergePublisher` に historical parser を追加せず、Git / coordination / Index の既存 primitive を別 orchestration から利用する。Pending record の durable write と power-loss guarantee は [canonical-power-loss-durability](../canonical-power-loss-durability/ADR.md) の primitive に従う。

この Decision は review/publication workflow の Product Contract である。Current Format v2 の ordered padding effect、v1→v2 edge、clean committed source からの隔離 candidate preparation は production に接続済み。LFS transport と ambiguity resolution はここで決めない。

## Unknowns

`hamii migrate prepare --json` は actual Current Format validator と一時 fresh Index check を通した immutable candidate OID を返す。Production migration-specific pending gate / record、source ref CAS、published Index generation、CLI review/accept、restart recovery、actual LFS transfer、power-loss primitive との接続は未実装。Git LFS transfer は必要 object の fail-closed 検証とは別に確認する。

## Required Evidence

- [Migration worktree safety](spikes/worktree-safety/SPIKE.md)

## Decision Criteria

[Worktree safety Spike](spikes/worktree-safety/SPIKE.md) の [21-case matrix](spikes/worktree-safety/artifacts/review-publication-matrix.json) は clean review/reject、dirty rejection、semantic/asset failure、source move と CAS race、unknown ref、Index failure、SIGKILL 5地点を含む。[Workflow comparison](spikes/worktree-safety/artifacts/workflow-comparison.md) は isolated candidate と mutable branch / source-in-place を比較し、text merge が成功し得ても publication が CAS で拒否する negative control を記録する。Full gate は14 checks 成功、Swift test 251 実行・失敗0・skip58。Release `HamiiMigrations` build 成功。Evidence commit `328bee98bd794899ecd879bc6d8b29a78fa82792` の [exact-SHA CI](https://github.com/9uiLe/hamii/actions/runs/36503082850) は成功。

この Evidence は process-stop と test-only target adapter の範囲であり、production v2 / Index publication や power loss を証明しない。Decision と Spike は先に Git history に残し、production implementation・validation・Current Architecture への反映が終わるまで ADR は削除しない。

## Related Decisions

- [migration-core-boundary](../migration-core-boundary/ADR.md)
- [migration-ambiguity-resolution](../migration-ambiguity-resolution/ADR.md)

## Status

Implementation Required
