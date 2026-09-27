# Canonical collaboration and writer model

## Context

`.hamii/write.lock` が協調させるのは hamii ↔ hamii の保存であり、Git CLI や他の editor には強制できない。journal は hamii save transaction の crash / interrupted write recovery に使う。観測していない外部 bytes の復旧は保証しない。

## Decision to Make

hamii の正式な Canonical collaboration / writer model を何とするか。同一 worktree の writer guarantee と、独立 writer の変更を利用可能な Project へ統合する条件を一つの Product Contract として決める。

## Constraints

外部 bytes を無断上書きしない。競合が疑われたら保存を中断する。Git repository は共有正本であり、hamii のみが file system を所有する前提にしない。同一 worktree への非協調 writer を正式な safe collaboration path として扱わない。Index 側の [CanonicalSnapshot Spike](../index-consistency/spikes/consistent-canonical-snapshot/SPIKE.md) と [Shared Worktree Generation Spike](../index-consistency/spikes/shared-worktree-generation/SPIKE.md) は、この writer coordination の保証範囲を入力条件として使うが、複数 writer の許可・統合方式を決めない。Index の safe fast path はこの ADR で定める writer guarantee に依存する。

## Options

正式な writer model の候補は、worktree ごとの coordinated writer domain と別 worktree / branch の validated merge、または同一 worktree の非協調 writer を含む共同編集である。後者の lossless 保証は現在の check/replace race 反例を解決できていない。hamii-managed Git operation adapter と semantic merge gate は前者を成立させる実装候補である。単なる pre/post fingerprint は check と replace の race を閉じない。

External-change detection は正式な writer model の外で起きた変更に対する defense-in-depth であり、すべての race を閉じることを Product Contract の成立条件とはしない。

## Current Hypothesis

**実装進捗:** `WorktreeCoordinator` が Canonical save / read、managed `git switch`、validated merge publication の lock・client observation epoch・pending gate を共有する。`ValidatedMergePublisher` は immutable candidate を retention ref で保持し、source ref CAS、Canonical verification、full LocalIndex rebuild の後に gate を解除する。`git recover` は既知 old/candidate ref から復旧し、unknown ref は拒否する。Production の一般 Index generation protocol と power-loss durability は別 ADR で検証する。

**Confirmed:** 現行 lock は hamii 同士だけが尊重する。journal は旧新 bytes のみを保持する。**Measured:** load 後・save 前の同一 revision 外部編集は旧 API で上書きされた。期待 Document の bytes 照合を保存境界へ追加した後、同じ逐次条件では conflict として中断し外部 bytes を保持した。**Measured in a minimal APFS model:** content check と atomic replace の間の非協調 edit は上書きされ、旧新 journal から復旧不能だった。これは production の全 interleaving を測った結果ではない。現行実装に非協調同時書込の lossless 保証はない。

**Prototype boundary:** 同じ worktree の hamii GUI / CLI / AI、hamii-managed Git operation、CanonicalSnapshot / Index generation / Query を共通の worktree lock と generation protocol に参加させる試験を行った。現行 `CanonicalRepository` の save lock だけではこの全体 protocol は成立しない。直接実行する Git CLI や外部 editor は lock を迂回できる。

**New narrow evidence:** raw `git switch` は現行 `.hamii/write.lock` を無視した。別 worktree の Git text merge が成功しても、Component shard 削除と instance 追加の合成で `component.missing` となり、現行 validation / inspect / index rebuild は拒否した。正常 merge の別ケースでは両 branch と merged manifest が revision 3 のまま Canonical contents が変化し、旧 Index の検索は `staleIndex` を返した。一方、旧 revision 3 の `page create` は merge 後も受理され、revision guard だけでは client session を失効させられない。これは validated merge gate と client session resync の必要性を示すが、それらの production protocol の成立証明ではない。

## Decision

**Product Contract:** 一つの worktree は一つの coordinated writer domain とする。hamii GUI、hamii CLI / AI、hamii-managed Git operation は、共通の worktree lock、generation、recovery、validation を通す。raw Git CLI、外部 editor / script / AI、その他 hamii protocol に従わない writer による同一 worktree の直接変更は、safe collaboration path として保証しない。外部変更の検知と保存中断は defense-in-depth であり、非協調 writer の全 race を閉じる保証ではない。

独立 writer は別 branch / worktree で作業する。統合は Git merge **candidate** を Canonical parse、schema、stable ID、reference、Scope / Component、その他 Authoring rule で検証し、同じ source state に結び付いた Index generation を構築・検証してから publish する。Git merge exit 0 だけでは hamii merge success と扱わない。失敗時は candidate を拒否し、双方の有効な branch / worktree を保持する。publish と client session 再同期の具体的 protocol は未実装であり、後者の state precondition は [Canonical state precondition ADR](../canonical-state-precondition/ADR.md) が決める。Index freshness / recovery は [Index consistency ADR](../index-consistency/ADR.md) が決める。

## Unknowns

残る実装・検証は managed Git switch の production generation / Index 連携、partial Git state の修復 UX、worktree identity と移動、publication の ownership 不明 Git lock での fail-closed recovery と power-loss durability。`git merge check` は一時 worktree 内の semantic validation と一時 Index rebuild を行い、公開しない。Publication の停止復旧と残課題は [Validated merge publication ADR](../validated-merge-publication/ADR.md) が扱う。Client / Preview token の選択は別 ADR。Power loss は [Power-loss ADR](../canonical-power-loss-durability/ADR.md)。

## Required Evidence

- [External writer interleaving](spikes/external-writer-interleaving/SPIKE.md): check と atomic replace の間の非協調 writer を検証する。
- [Worktree isolation](spikes/worktree-isolation/SPIKE.md): separate worktree の逐次編集と、20 組の重なった CLI mutation を確認。同時 Git 操作と crash recovery は未測定。
- [External change detection](spikes/external-change-detection/SPIKE.md): ready barrier で checkout した場合と load/save 間の逐次外部編集の conflict / bytes 保持を確認。その他の interleaving は未測定。
- [Concurrent worktree merge](spikes/concurrent-worktree-merge/SPIKE.md): 非競合 Page と同一 Text property の merge に加え、Git text merge 成功後の `component.missing`、merge 前後で同じ revision でも Canonical identity が異なるケース、旧 Index の `staleIndex` 拒否、旧 revision mutation の受理を確認。Production merge gate と client session invalidation は未実装。
- [Managed Git operation](spikes/managed-git-operation/SPIKE.md): raw `git switch` は `.hamii/write.lock` を無視する。試験用 wrapper では reader と switch を同じ lock で囲み generation を進めた。Production adapter は未実装。
- [Shared generation process-stop matrix](../index-consistency/spikes/shared-worktree-generation/SPIKE.md): 試験用 coordinated boundary で別 OS process の writer / reader の flock attempt/acquire を確認し、4地点で writer を SIGKILL。Product Contract はこの保証境界を採用するが、production generation protocol の成立証明にはならない。
- [Git lock ownership](../validated-merge-publication/spikes/git-lock-ownership/SPIKE.md): 生存中の raw Git subprocess が、hamii recovery が削除していた ref lock と index lock を取得できる。External writer を Product Contract に含める Evidence ではなく、hamii が ownership 不明 lock を破壊しないための defense-in-depth の入力である。
- Managed switch implementation tests: 同一 revision の branch switch 後に旧 client token を拒否する。pending・switched・validated の注入停止で通常の Canonical observation を拒否し、既知 HEAD と valid Canonical state の recovery 後に再開する。Unsupported Canonical format の target は source branch へ戻し、旧 token は失効したままにする。注入停止は SIGKILL / power loss の再検証ではない。
- Isolated merge candidate CLI smoke: 非競合 merge を一時 worktree で Canonical validation・一時 Index rebuild まで通し、source HEAD と client token を変更しない。Git text merge 成功後の `component.missing` を拒否し、両側の valid branch を保持する。Candidate publication は未実装。

## Decision Criteria

Product Contract の判断条件は、正式な共同作業経路で変更を黙って失わないこと、非協調 writer に保証を誤適用しないこと、Git text merge と Canonical semantic merge を区別できること。実装完了条件は、lock / recovery / generation を通る managed Git operation、隔離した merge candidate の検証と publish、失敗時の双方の branch 保持、client / Index 側との境界の検証である。

## Status

Implementation Required
