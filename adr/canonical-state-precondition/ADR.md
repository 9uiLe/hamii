# Canonical state precondition for clients and mutations

## Context

`Document.revision` は hamii semantic mutation の順序を表す。別 branch がそれぞれ revision 3 に進んだ後の Git merge では、merged manifest も revision 3 のまま Canonical contents が変化した。旧 revision 3 を持つ CLI mutation は受理された。[Merge Spike](../git-external-write-coordination/spikes/concurrent-worktree-merge/SPIKE.md) の観測であり、revision だけでは client が観測した Canonical state の同一性を証明できない。GUI / CLI / AI、Native Preview、Patch base、Undo / Redo の session に共通する問題である。

## Decision to Make

Client / Preview / mutation が、自分の観測した Canonical state と現在の Canonical state が同一であることを何で証明し、未知の transition があればどの境界で拒否・再同期するか。

## Constraints

観測していない Canonical state transition が存在した場合、古い session / token からの mutation を受理しない。未証明なら fail closed。`DocumentRevision`、Canonical state identity、coordinated worktree generation、Index generation、client session token を先に同一概念と仮定しない。Git commit SHA だけでは working Canonical bytes を表せない。Index の freshness 判定は [Index consistency ADR](../index-consistency/ADR.md)、writer の許可・統合経路は [External Git Write ADR](../git-external-write-coordination/ADR.md) の責務とする。Preview の target runtime transport は本 ADR の責務ではない。

## Options

CanonicalSnapshot 由来の state identity、coordinated worktree generation、session epoch、これらを組み合わせた token を比較した。`DocumentRevision` 単独は same-revision 反例、contents identity 単独は A → B → A の反例、process-local epoch 単独は restart / 別 process の知識欠落により除外する。Opaque token の具体的 encoding は Product semantics とは別の実装事項。

## Current Hypothesis

**実装仮説、未検証:** client が opaque value を mutation / patch に付け、Application Service が coordinated observation boundary で照合する。Exact Canonical path/bytes identity、worktree identity、永続 transition marker を独立入力として結合する候補がある。Hash / UUID / generation の encoding と persistence protocol は実装・検証対象。IndexGeneration を client token と同一視しない。Raw Git 等の protocol 非参加 writer は Product Contract の保証外であり、観測できた変更は fail closed にする。

## Decision

`ClientPrecondition` は、client が操作の基点とした **exact Canonical observation** を指す opaque value とする。Coordinated writer domain 内で client が観測していない state transition が一度でもあれば、その precondition による mutation / patch は拒否する。同じ bytes に戻る A → B → A でも旧 precondition は再有効化しない。`DocumentRevision` は semantic mutation order と journal / Preview ordering に残すが、state identity の十分条件には使わない。

Application Service は GUI と CLI / AI の mutation に同じ precondition rule を適用する。Preview snapshot / patch も ordering と base state を分け、Preview が持つ base state と patch の precondition が一致しない場合は拒否して snapshot 再同期する。Preview transport は対象外。`CanonicalStateIdentity`、coordinated `WorktreeGeneration`、`IndexGeneration`、`ClientPrecondition` は別概念として保持し、内部実装で値を共有する場合でも各保証を別に検証する。

Process restart 後は journal recovery と coordinated observation の再確立が完了するまで新しい precondition を発行しない。既存 token は、同じ worktree の同じ Canonical observation と、その間に未観測の coordinated transition がないことを検証できた場合だけ有効とする。欠損・破損・観測不能は Unknown として拒否する。Protocol 非参加 writer の同一 worktree 変更は正式保証外であり、検出した差異は拒否する。External writer の A → B → A を無通知で検知できる保証は主張しない。

## Unknowns

実装上の残作業は coordinated transition marker の永続化と crash ordering、branch switch / merge の token 更新、別 GUI / CLI process と restart での照合、Preview patch acknowledgement と Undo / Redo base の結合、unknown external writer に対する defense-in-depth、token 計算・保持の cost、既存 `--revision` / Preview revision API の置換・追加である。Managed Git / validated merge の実装は External Git Write ADR、Index generation は Index ADR が扱う。

## Required Evidence

- [Same-revision state change](spikes/same-revision-state-change/SPIKE.md): 2 client の通常 mutation 競合は拒否。same-revision branch switch / merge では旧 revision mutation を受理。raw Git A → B → A は bytes と revision が戻る。Preview revision-only gate は同一 revision の別 observation を区別できない。候補 token の production correctness は未検証。
- [Existing merge result](../git-external-write-coordination/spikes/concurrent-worktree-merge/artifacts/semantic-and-resync-result.json): revision 3 のまま Canonical state が変わり、旧 revision mutation が受理された。Index は `staleIndex` を返した。

## Decision Criteria

未観測の **coordinated** Canonical transition に対する false current を 0 にすること。merge、restart、Unknown で precondition の意味が一貫し、GUI / CLI / Preview / Patch の各入口が同じ Application rule に従うこと。実装検証では発行・照合 cost、再同期 UX、crash ordering、実装複雑度を測る。Raw external writer の保証境界を拡張しない。

## Status

Implementation Required
