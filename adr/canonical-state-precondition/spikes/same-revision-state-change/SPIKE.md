# Same revision, different Canonical state

## Related Decision

[Canonical state precondition ADR](../../ADR.md) の client / mutation / Preview session token。

## Hypothesis

**Tentative:** `DocumentRevision` と別の Canonical state precondition を持てば、同じ revision の別 state を区別し、古い session の mutation / patch を拒否できる可能性がある。具体的 token は未選択。

## Questions

- same revision の別 branch / merge / branch switch を何が識別するか。
- process restart 後と二つの GUI / CLI session で token をどう再確立するか。
- Preview snapshot / patch の base と Undo / Redo をどう失効させるか。
- Unknown / external change を current と誤認せずに扱えるか。

## Prototype Scope

使い捨て worktree と実 `ProjectService` / CLI、必要に応じて Preview protocol の test harness を使う。各 client が観測した state と mutation / patch の発行時 state を記録し、候補 token ごとの accept / reject を比較する。既存の merge probe を反例の入力として再利用する。

## Out of Scope

Product Contract の writer 境界の再決定、Index recovery algorithm、Preview Host transport、未検証 token の production 導入。

## Measurements

各 interleaving の `DocumentRevision`、Canonical contents identity、coordinated generation（該当する場合）、client token、mutation / patch outcome、restart 後の outcome と照合 cost。False current を最優先で記録する。

## Success Criteria

client が観測していない Canonical transition の後、古い token による mutation / patch を拒否する。新しい state を取得して再同期した client は操作を再開できる。

## Failure Criteria

同じ manifest revision を根拠に異なる Canonical state への mutation / patch を受理する。あるいは外部変更の観測が Unknown なのに current を返す。

## Result

**Confirmed, current CLI, macOS 27.0 / Git 2.52.0:** Case A: 2 client が revision 0 を観測し、A が Page を作成した後、B の revision 0 mutation は exit 3 / `conflict` で拒否された。Case C: 同じ revision 1 の異なる branch へ切り替えると Canonical contents は変わったが、旧 revision 1 の mutation が成功した。CLI command ごとに別 OS process を起動しており、Case D の process-local な知識は引き継がれない。Case B は [既存 merge probe](../../../git-external-write-coordination/spikes/concurrent-worktree-merge/SPIKE.md) で revision 3 のまま contents が変わり、旧 mutation が成功した。Case E: 実 `PreviewRevisionGate` に base / applied revision 3 の異なる Canonical observation を与えても、現行 protocol は区別する field を持たず patch を受理した。

**Confirmed ABA counterexample outside the coordinated writer contract:** raw Git で State A → B → A と切り替えると最初と最後の Canonical bytes、manifest revision は同一になり、旧 revision mutation が成功した。Content digest だけでも最初と最後を区別できない。raw Git は正式な coordinated writer domain の外であり、この試験を保証対象内の failure と一般化しない。一方、hamii-managed transition では A → B → A も観測していない transition として扱うなら、永続する transition marker が必要という判断材料になる。

**Not measured:** 実 GUI の別 session、candidate token の implementation、Preview Host 上の patch、coordinated Git adapter、process restart 後の永続 token 検証、外部 writer との race。今回の Preview test は protocol gate 単体であり transport 評価ではない。

## Conclusion

`DocumentRevision` 単独は候補から除外する。Content identity 単独も A → B → A の transition を区別しない。Client precondition は「client が基点とした exact Canonical observation」を指し、coordinated writer domain 内の未観測 transition を拒否する必要がある。具体的な encoding や WorktreeGeneration / IndexGeneration との同一性は、この Spike だけでは証明されない。

## Artifacts

- [probe.py](artifacts/probe.py)、[result.json](artifacts/result.json): CLI / Git の2 client、同一 revision branch switch、process restart、raw Git ABA。
- [CanonicalStatePreconditionSpikeTests.swift](../../../../Tests/HamiiTests/CanonicalStatePreconditionSpikeTests.swift): 現行 PreviewRevisionGate の同一 revision 反例。
- [Existing merge probe result](../../../git-external-write-coordination/spikes/concurrent-worktree-merge/artifacts/semantic-and-resync-result.json): merge の Case B。
