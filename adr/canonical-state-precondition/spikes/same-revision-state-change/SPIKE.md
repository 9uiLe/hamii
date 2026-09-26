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

**Existing evidence only; this Spike's candidate comparison is not run:** [External Git merge probe](../../../git-external-write-coordination/spikes/concurrent-worktree-merge/SPIKE.md) は、merge 前後で revision 3 が同じでも Canonical contents が変わり、旧 revision 3 の `page create` が受理されることを確認した。既存 Index は同じ変更を `staleIndex` として拒否した。これは revision-only precondition の反例であり、新 token 候補の正しさはまだ検証していない。

## Conclusion

`DocumentRevision` 単独は候補から除外する。Client session token / state identity の方式は追加 interleaving と候補比較まで決めない。

## Artifacts

この Spike 固有の artifact はまだない。既存の [merge probe result](../../../git-external-write-coordination/spikes/concurrent-worktree-merge/artifacts/semantic-and-resync-result.json) を入力 evidence とする。
