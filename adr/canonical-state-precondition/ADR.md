# Canonical state precondition for clients and mutations

## Context

`Document.revision` は hamii semantic mutation の順序を表す。別 branch がそれぞれ revision 3 に進んだ後の Git merge では、merged manifest も revision 3 のまま Canonical contents が変化した。旧 revision 3 を持つ CLI mutation は受理された。[Merge Spike](../git-external-write-coordination/spikes/concurrent-worktree-merge/SPIKE.md) の観測であり、revision だけでは client が観測した Canonical state の同一性を証明できない。GUI / CLI / AI、Native Preview、Patch base、Undo / Redo の session に共通する問題である。

## Decision to Make

Client / Preview / mutation が、自分の観測した Canonical state と現在の Canonical state が同一であることを何で証明し、未知の transition があればどの境界で拒否・再同期するか。

## Constraints

観測していない Canonical state transition が存在した場合、古い session / token からの mutation を受理しない。未証明なら fail closed。`DocumentRevision`、Canonical state identity、coordinated worktree generation、Index generation、client session token を先に同一概念と仮定しない。Git commit SHA だけでは working Canonical bytes を表せない。Index の freshness 判定は [Index consistency ADR](../index-consistency/ADR.md)、writer の許可・統合経路は [External Git Write ADR](../git-external-write-coordination/ADR.md) の責務とする。Preview の target runtime transport は本 ADR の責務ではない。

## Options

CanonicalSnapshot 由来の state identity、coordinated worktree generation、session epoch、これらを組み合わせた token を比較する。`DocumentRevision` 単独は反例により除外する。Token の形式、永続化、公開範囲、失効と再確立の protocol は未決定。

## Current Hypothesis

**Tentative:** client が受け取った opaque state precondition を mutation / patch に付け、Application Service が同じ coordinated observation boundary で照合する。branch switch / merge / process restart / unknown external change は旧 token を失効させるか Unknown に落とす。Token が CanonicalSnapshot identity と worktree generation のどちらを保持するかは Spike 後に決める。

## Unknowns

同じ contents に戻る transition の扱い、branch switch と merge の token 発行点、別 GUI / CLI process の再同期、process restart での再確立、Preview patch acknowledgement と Undo / Redo base の結合、unknown external writer に対する fail-closed boundary、token 計算・保持の cost。既存 `--revision` / Preview revision API をどう変更するかも未決定。

## Required Evidence

- [Same-revision state change](spikes/same-revision-state-change/SPIKE.md): merge の既存反例を起点に、same-revision / different branch、branch switch、process restart、二つの GUI / CLI session、Preview session を比較し、古い token による mutation / patch を拒否できる条件を測る。
- [Existing merge result](../git-external-write-coordination/spikes/concurrent-worktree-merge/artifacts/semantic-and-resync-result.json): revision 3 のまま Canonical state が変わり、旧 revision mutation が受理された。Index は `staleIndex` を返した。

## Decision Criteria

未観測の Canonical transition に対する false current を 0 にすること。coordinated writer domain、merge、restart、Unknown で precondition の意味が一貫し、GUI / CLI / Preview / Patch の各入口が同じ Application rule に従うこと。安全性を満たす候補について発行・照合 cost、再同期 UX、実装複雑度を比較する。

## Status

Spike Required
