# Validated merge candidate publication

## Context

`hamii git merge check` は一時 worktree で Git merge、Canonical semantic validation、一時 Index rebuild を行い、source worktree を変更しない。Product Contract は、検証済み candidate と同じ CanonicalSnapshot に由来する Index generation だけを利用可能な Project として publish することを要求する。Git の ref・worktree 更新、Canonical files、Repository 外の Index、client token は単一の filesystem transaction ではない。現行 `WorktreeCoordinator` は lock と pending gate を持つが、merge publication の crash ordering は未検証である。

## Decision to Make

検証済み merge candidate と対応する Index generation を、停止・再起動時にも未検証または中間状態を利用可能にせず、どの protocol で source worktree へ publish するか。

## Constraints

- `1 worktree = 1 coordinated writer domain` と同じ `WorktreeCoordinator` を使う。
- ClientPrecondition は Canonical state 変更前に失効する。DocumentRevision、CanonicalStateIdentity、WorktreeGeneration、IndexGeneration を同一概念と仮定しない。
- Candidate の Git merge exit 0 は publish authorization ではない。Canonical semantic validation と source binding が必要。
- Index は Repository 外の derived data であり、source CanonicalSnapshot と結び付いた generation だけを公開する。中間 Index と future Index を検索に見せない。
- 失敗時に有効な source / target branch の history と Canonical data を失わない。Pending / unknown state は fail closed。
- Raw Git 等の非協調 writer は正式保証外。Power-loss durability の判定は [Power-loss ADR](../canonical-power-loss-durability/ADR.md) と重複させない。

## Options

1. Pending gate と worktree lock の下で source branch を candidate commit へ進め、同じ Snapshot から Index generation を作成・公開し、復旧後に gate を解除する。
2. Candidate commit への ref 更新と worktree materialization を別 journal で追跡し、失敗時に既知状態へ rollback / roll forward する。
3. Immutable worktree / generation を作り、利用可能な Project を指す pointer を切り替える。

各方式の Git state、Canonical files、Index publication、client resync の停止地点を実測する。Options は採用判断ではない。

## Current Hypothesis

**Tentative:** `WorktreeCoordinator` の pending gate が source の通常操作を遮断する間に、candidate の identity、Git HEAD、CanonicalSnapshot、Index source を検証し、再起動時は一つの既知 generation へ復旧する。In-place publish と immutable pointer のいずれが安全かは未決定。現行の `git merge check` は candidate validation までで公開しない。

## Unknowns

Git ref と worktree 更新の停止後状態、candidate commit の保持、Index generation の atomic publication、crash 時の旧新どちらを選ぶか、candidate cleanup、concurrent query の serialization、source と candidate の CanonicalSnapshot identity の結合。停電耐久性は別 ADR。

## Required Evidence

- [Publication stop matrix](spikes/publication-stop-matrix/SPIKE.md): 実 Git worktree と SQLite Index の in-place fast-forward 試作で、4 つの phase 間 SIGKILL 後に gate・recovery・query・client token を検証した。Git / SQLite 更新処理中の停止と production generation binding、代替方式との比較は未完了。
- 現行の [semantic merge result](../git-external-write-coordination/spikes/concurrent-worktree-merge/SPIKE.md) と `scripts/smoke-merge-candidate.py` は candidate validation の Evidence。Publication 成功の Evidence ではない。

## Decision Criteria

未検証 candidate、中間 Canonical state、source が一致しない Index generation から Query / mutation を許可しない。停止後に既知の旧または新 CanonicalSnapshot へ復旧でき、元の有効 branch / worktree を保存する。正しさを満たす候補について publication latency、recovery time、Index rebuild cost、実装複雑度を比較する。

## Status

Spike Required
