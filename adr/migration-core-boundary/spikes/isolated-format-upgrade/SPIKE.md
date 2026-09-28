# Isolated format upgrade

## Related Decision

[ADR.md](../../ADR.md) の historical parser と Current Core の依存境界。

## Hypothesis

Raw Canonical file bytes と historical parser / edge registry を依存のない migration target に置けば、Current Core に historical type を入れず、各 edge 後に検証した candidate bytes だけを current-system validation へ渡せる。Ordered effects の test-only v2 と synthetic v3 は module boundary の probe であり、production schema ではない。

## Questions

v1→v2→v3 の path 解決・中間検証・同一入力での byte determinism は独立 target で成立するか。Current Core / Format / Index に historical type が漏れないか。元 repository の bytes、stable ID / cross-file references、Document format 以外の version を保てるか。失敗後に部分 candidate が受理されないか。候補 bytes を外側の test harness が current-system validation / fresh Index rebuild へ渡せるか。

## Prototype Scope

計画 commit 後に test-only の独立 module / helper を作り、`[String: Data]` の raw Canonical map を入力・出力にする。Current `Document` を migration engine の入出力にしない。

- 有効な v1 fixture に manifest、Page / AppSurface、Screen / nested Layer、`layout.paddingTokenID`、ComponentDefinition / nested ComponentInstance / slotContent、ArchitectureScope、Token、Asset、CapabilityDeclaration を含める。Agent profile 等の独立 version file は exact-byte passthrough とする。
- Test-only v1→v2 edge は padding token を ordered padding effect に移し、`formatVersion` と `versions.document` を同時に 1/1→2/2 とする。v2→v3 は意味を変えない deterministic normalization のみで 2/2→3/3 とする。**Probe v3 は edge chaining の Evidence のみで、製品 Format v3 の提案ではない。**
- Registry で 1→2、2→3、1→3（両 edge）、3→3（no-op）、1→unknown、3→1（downgrade rejection）を検証する。1→3 は各 edge 直後に intermediate validation を行い、最終検証だけで済ませない。
- 同じ source から3回 candidate の paths / bytes / classification / diagnostics を比較し、direct 1→3 と stepwise 1→2→3 の bytes を比較する。Source tree の before/after digest を一致させる。各 edge の deterministic failure injection では source 不変・partial candidate 不採用を確認する。
- Candidate の stable IDs / refs、scope ownership、asset / token / page / surface refs を semantic projection と raw JSON 検査で照合する。Current-format adapter と fresh Index rebuild は **test harness 側**で行い、migration module が Core / Format / Index を import しない。
- `Sources/HamiiCore`、`Sources/HamiiFormat`、`Sources/HamiiIndex` に historical type / version branch がなく、独立 migration target が Core / Format / Index に依存しないことを dependency graph と text search で確認する。

## Out of Scope

Production Format v2 / ordered effect API / actual v1→v2 edge、`MigrationPreflight.currentDocumentFormatVersion` 変更、CLI migrate execution、Samples、TargetPlanner / Generator effect support、全 historical version 配布、ambiguous value の Human 解決、worktree / branch publication と recovery UX。試作型を production schema とみなさない。

## Measurements

`artifacts/migration-matrix.json` に `inputVersion`、`targetVersion`、`resolvedEdges`、`classification`、`sourceDigestBefore/After`、`candidateDigest`、`repeatDigest`、`intermediateValidation`、`finalValidation`、`referencePreservation`、`freshIndexRebuild` を記録する。成功/失敗の error category と、v1→v2→v3 の marker、source/candidate path 数、非対象 file passthrough も記録する。`artifacts/dependency-boundary.md` に target/module、imports、historical/current types の有無、role を記録する。時間 benchmark はこの decision の条件ではない。

## Success Criteria

- 独立 migration target が raw bytes の v1→v2、synthetic v2→v3、registry による 1→3 を実行し、各 edge 後に検証する。
- 同じ source の3回と direct / stepwise 1→3 で paths、全 bytes、classification、diagnostics が一致する。
- Source repository は byte-identical、失敗注入後も source と公開 candidate は不変。
- Stable ID / cross-file refs / owner Scope と独立 version file の bytes を保ち、全 fixture の意味分類を根拠付きで記録する。
- Migration module から Core / Format / Index import は 0、Current Core / Format / Index の historical type / branch は 0。
- Test harness が candidate bytes を独立に検証し、fresh LocalIndex を rebuild できる。古い published Index を Evidence に使わない。
- Production Current Format は v1 のままで、ordered effects は production に追加しない。Full gate、Release HamiiMigrations、exact pushed SHA CI が成功する。

## Failure Criteria

Core / Format / Index の historical dependency が必要、source tree の変更が必要、同一 input が非決定的、intermediate v2 が invalid でも v3 が成功する、失敗後に partial candidate を受理する、意図を推測しないと v1→v2 を分類できない、または production v2 schema / review workflow の実装なしに module boundary を試せない場合は採用判断へ進まない。曖昧さは [migration-ambiguity-resolution](../../../migration-ambiguity-resolution/ADR.md)、publication は [migration-review-protocol](../../../migration-review-protocol/ADR.md) に分ける。

## Result

Not yet validated。実測値と成果物 link を記録する。

## Conclusion

Not yet validated。ADR の判断への影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけこの Spike の `artifacts/` を作る。
