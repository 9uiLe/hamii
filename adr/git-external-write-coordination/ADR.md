# External Git writes during Canonical save

## Context

`.hamii/write.lock` が協調させるのは hamii ↔ hamii の保存であり、Git CLI や他の editor には強制できない。journal は hamii save transaction の crash / interrupted write recovery に使う。観測していない外部 bytes の復旧は保証しない。

## Decision to Make

1 worktree を 1 coordinated writer domain として扱う条件、非協調 external modification の検知・保存中断条件、別 branch / worktree 間の validated merge protocol を決める。

## Constraints

外部 bytes を無断上書きしない。競合が疑われたら保存を中断する。Git repository は共有正本であり、hamii のみが file system を所有する前提にしない。同一 worktree への非協調 writer を正式な safe collaboration path として扱わない。Index 側の [CanonicalSnapshot Spike](../index-consistency/spikes/consistent-canonical-snapshot/SPIKE.md) と [Shared Worktree Generation Spike](../index-consistency/spikes/shared-worktree-generation/SPIKE.md) は、この writer coordination の保証範囲を入力条件として使うが、複数 writer の許可・統合方式を決めない。Index の safe fast path はこの ADR で定める writer guarantee に依存する。

## Options

worktree 分離 + validated merge、保存前後の external-change detection + conflict、協調可能な Git operation adapter、semantic merge boundary。単なる pre/post fingerprint は check と replace の race を閉じない。

## Current Hypothesis

**未確定:** 「1 worktree = 1 coordinated writer domain。独立 writer は別 branch / worktree と validated merge で協働」が有力仮説。**Confirmed:** 現行 lock は hamii 同士だけが尊重する。journal は旧新 bytes のみを保持する。**Measured:** load 後・save 前の同一 revision 外部編集は旧 API で上書きされた。期待 Document の bytes 照合を保存境界へ追加した後、同じ逐次条件では conflict として中断し外部 bytes を保持した。**Measured in a minimal APFS model:** content check と atomic replace の間の非協調 edit は上書きされ、旧新 journal から復旧不能だった。これは production の全 interleaving を測った結果ではない。現行実装に非協調同時書込の lossless 保証はない。

**Spike 用の coordinated writer boundary（製品保証として未決定）:** 同じ worktree で Canonical bytes を変更できる hamii GUI / CLI / AI の全操作、hamii 管理下の Git branch / checkout / pull、および CanonicalSnapshot / Index generation / Query が、同一の worktree lock と generation protocol に参加する条件を試す。`CanonicalRepository` の単一 save lock だけでは save 後の別 process への generation 通知を保証しない。VS Code、直接実行する Git CLI、外部 script、外部 AI、その他 lock に従わない writer はこの境界の外に置く。境界外の同一 worktree 変更は shared generation を更新せず false current を作る反例があり、正式な safe collaboration path としない。独立 writer は separate worktree / branch と validated merge で扱う候補を維持する。これを正式 Product Contract として採用できるか、境界を技術的にどう強制・検出するかは未解決。

## Unknowns

worktree 分離の運用条件、checkout/pull/edit の検出可能範囲、check/replace 間の race を含む fail-closed boundary、同じ bytes へ収束する編集、merge conflict と semantic validation、conflict UX、複数プロセスの lock semantics。

## Required Evidence

- [External writer interleaving](spikes/external-writer-interleaving/SPIKE.md): check と atomic replace の間の非協調 writer を検証する。
- [Worktree isolation](spikes/worktree-isolation/SPIKE.md): separate worktree の逐次編集と、20 組の重なった CLI mutation を確認。同時 Git 操作と crash recovery は未測定。
- [External change detection](spikes/external-change-detection/SPIKE.md): ready barrier で checkout した場合と load/save 間の逐次外部編集の conflict / bytes 保持を確認。その他の interleaving は未測定。
- [Concurrent worktree merge](spikes/concurrent-worktree-merge/SPIKE.md): 非競合 Page と同一 Text property の merge を確認。semantic-only conflict は未測定。
- [Shared generation process-stop matrix](../index-consistency/spikes/shared-worktree-generation/SPIKE.md): 試験用 coordinated boundary で別 OS process の writer / reader の flock attempt/acquire を確認し、4地点で writer を SIGKILL。非協調 writer の扱いと正式な writer contract は未決定。

## Decision Criteria

正式な共同作業経路で外部変更を黙って失わないこと、競合が疑われる場合に保存を中断すること、復旧が再実行可能であること、ユーザーが conflict の対象を特定できること。各保証が協調 writer と非協調 writer のどちらに適用されるかを明記する。

## Status

Spike Required
