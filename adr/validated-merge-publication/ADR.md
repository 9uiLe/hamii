# Validated merge candidate publication

## Context

`hamii git merge check` は一時 worktree で Git merge、Canonical semantic validation、一時 Index rebuild を行い、source worktree を変更しない。`ValidatedMergePublisher` は candidate commit を固定し、source ref CAS、Canonical verification、full Index rebuild、gate release を orchestration する。Product Contract は、検証済み candidate と同じ CanonicalSnapshot に由来する Index だけを利用可能な Project として publish することを要求する。Git の ref・worktree 更新、Canonical files、Repository 外の Index、client token は単一の filesystem transaction ではない。

## Decision to Make

検証済み merge candidate と対応する Index generation を、停止・再起動時にも未検証または中間状態を利用可能にせず、どの protocol で source worktree へ publish するか。

## Constraints

- `1 worktree = 1 coordinated writer domain` と同じ `WorktreeCoordinator` を使う。
- ClientPrecondition は Canonical state 変更前に失効する。DocumentRevision、CanonicalStateIdentity、WorktreeGeneration、IndexGeneration を同一概念と仮定しない。
- Candidate の Git merge exit 0 は publish authorization ではない。Canonical semantic validation と source binding が必要。
- Index は Repository 外の derived data であり、source CanonicalSnapshot と結び付いた generation だけを公開する。中間 Index と future Index を検索に見せない。Canonical publication 後に Index が失敗しても Canonical を rollback せず、Query を拒否して再生成する。
- Git ref / working tree / Repository 外 SQLite の同時 atomic commit を要求しない。Durable pending state、immutable validated candidate、fail-closed gate、idempotent recovery を組み合わせる。
- `WorktreeCoordinator` は lock、epoch、pending gate の primitive に留め、Git・semantic validation・Index publication の orchestration を持たせない。
- 失敗時に有効な source / target branch の history と Canonical data を失わない。Pending / unknown state は fail closed。
- Raw Git 等の非協調 writer は正式保証外。Power-loss durability の判定は [Power-loss ADR](../canonical-power-loss-durability/ADR.md) と重複させない。

## Options

1. Validated candidate commit を保持し、pending gate の下で source ref を expected OID から candidate OID へ CAS 更新する。ref 更新を Canonical publication の commit point とし、worktree materialization、Canonical verification、Index generation publication を経て Ready にする。
2. Source ref とは別の immutable project pointer を commit point とし、検証済み candidate と派生 Index generation を指す pointer を切り替える。

各方式の Git state、Canonical files、Index publication、client resync の停止地点を実測する。Options は採用判断ではない。

## Current Hypothesis

**Tentative implementation detail:** `IndexGenerationID` の保存形式は production 検証が必要。[Git lock ownership Spike](spikes/git-lock-ownership/SPIKE.md) は、pending record と lock path のみでは停止した hamii subprocess の lock と生存中の raw Git process の lock を区別できないことを示した。Production recovery は ownership 不明 lock を削除せず gate を維持する。Candidate commit は `refs/hamii/merge-candidates/<publication-id>` で保持する。現在の Index generation storage / publication は [Current Architecture](../../docs/final-architecture.md) に記載する。

## Decision

検証済み candidate commit を publication source とし、source worktree で merge を再実行しない。Candidate は source / target commit OID、candidate OID、CanonicalSnapshot identity、検証済み Index source identity と共に保持する。Source worktree lock 下で source ref が expected OID と一致することを確認し、ClientPrecondition を先に失効させ、同じ gate として認識される pending publication record を記録する。Git ref の expected old OID → candidate OID の CAS を **Canonical publication commit point** とする。Ref CAS 後は candidate commit から working tree を materialize し、公開済み Canonical bytes が candidate identity と一致することを検証する。Index はその Canonical identity に結び付いた generation を別途 build / validate / publish し、最後に gate を解除する。

Pending 中は observe / mutation / query / preview mutation を Ready として扱わない。Recovery は、ref が expected old OID なら old state を保持して abort、candidate OID なら candidate へ roll-forward して検証と Index publication を完了、どちらでもなければ Unknown として gate を残す。Index failure では Canonical を rollback せず、Query を拒否して同一 CanonicalSnapshot から Index を再生成する。Git ref / Canonical files / SQLite の同時 atomic transaction は作らない。`WorktreeCoordinator` は lock / epoch / gate の primitive に留め、Git / validation / Index を組み合わせる publication orchestration は別責務とする。

この決定は [CAS and internal stops](spikes/cas-and-internal-stops/SPIKE.md) の process crash Evidence に基づく。Pending record の停電耐久性は [Power-loss ADR](../canonical-power-loss-durability/ADR.md) の durability primitive を要する。Production の `CanonicalSnapshot`・`IndexGenerationID` binding は full rebuild と merge gate に接続した。Git subprocess 所有者確認、一般の Index generation publication は別途検証が必要であり、試作の値を production guarantee に昇格させない。

## Unknowns

Production は candidate retention ref、pending record、source / candidate Canonical JSON identity、別ファイル full SQLite rebuild と rename を持つ。Index rows と source identity / `IndexGenerationID` を同じ SQLite transaction に記録し、公開済み Index の descriptor が build 結果と一致する場合だけ gate を解除する。残る検証は ownership 不明 Git lock での fail-closed recovery と明示的な manual repair boundary、candidate retention ref の orphan cleanup、large-project latency。停電耐久性と一般の Index 世代公開方式は別 ADR。

## Required Evidence

- [Publication stop matrix](spikes/publication-stop-matrix/SPIKE.md): 実 Git worktree と SQLite Index の in-place fast-forward 試作で、4 つの phase 間 SIGKILL 後に gate・recovery・query・client token を検証した。Git / SQLite 更新処理中の停止と production generation binding、代替方式との比較は未完了。
- [CAS and internal stops](spikes/cas-and-internal-stops/SPIKE.md): 実 Git ref CAS の transaction hook 内、Git materialization 内、試作用 Canonical verification / SQLite transaction、Index file replace / gate clear の直前・直後を SIGKILL で検証した。Old / candidate / unknown ref の fail-closed 分類と Index 欠損後の candidate 側 recovery を確認した。Production Snapshot / generation / durability は未検証。
- [Git lock ownership](spikes/git-lock-ownership/SPIKE.md): 生存中の外部 Git が同じ ref / index lock path を保持できる。Pending record と lock file の存在だけで interrupted hamii subprocess の所有物と断定できない。Production は両 lock の存在時に回復を拒否し gate を保持する。Live raw Git process を使う2件と、SIGKILL 後に test が死んだ process を確認して明示的に lock を除去する回帰試験を追加した。Operator 向け partial Git state 修復 UX は継続課題。
- `ValidatedMergePublicationTests` は production `ValidatedMergePublisher` と実 Git / SQLite を使用し、19 停止地点で別 OS process の writer を SIGKILL する。Reader の lock 競合、pending 中の observe / query / mutation 拒否、old / candidate の recovery、旧 client token 拒否、Index freshness、再 recovery の冪等性を回帰検証する。Git reference-transaction hook、smudge filter、SQLite transaction 内の停止を含む。これは process crash の Evidence であり、power-loss durability や一般の IndexGenerationID protocol の証明ではない。
- 現行の [semantic merge result](../git-external-write-coordination/spikes/concurrent-worktree-merge/SPIKE.md) と `scripts/smoke-merge-candidate.py` は candidate validation の Evidence。Publication 成功の Evidence ではない。

## Decision Criteria

未検証 candidate、中間 Canonical state、source が一致しない Index generation から Query / mutation を許可しない。停止後に既知の旧または新 CanonicalSnapshot へ復旧でき、元の有効 branch / worktree を保存する。正しさを満たす候補について publication latency、recovery time、Index rebuild cost、実装複雑度を比較する。

## Status

Implementation Required
