# Component Variant と Instance の解決

## Context

Variant の組合せが増えると保存量、override 競合、resolver cache、scope/capability validation の負荷が増える。

## Decision to Make

Definition/Variant/Instance を subtree copy なしで保存し、sparse delta と override をどの順に解決するか。

## Constraints

Scope owner は Definition に属する。Instance は公開された property/slot/path のみ override 可能。cycle は拒否。

## Options

全組合せ materialize、sparse variant delta、variant ごと別 Definition。

## Current Hypothesis

**受入仮説（整理 commit の CI 検証待ち）:** 下記 Decision の疎な表現と typed validation は、現在の Component IR / Canonical Format に接続できている。1,000 Instance の直接 resolve 測定は実行可能性の Evidence だが、production cache や局所再計算の性能は未検証。

## Decision

- Canonical representation は ComponentDefinition の base Layer tree、疎な ComponentVariant delta、Definition 参照と選択・値・slot・公開 override を持つ疎な ComponentInstance とする。resolved subtree を Instance 内や Canonical Data に複製しない。ownerScope は Definition に属する。
- 選択済み Variant が同じ property path へ複数書く場合は、値が同じでも `conflictingVariants` として拒否する。正常に解決でき、書込み対象が最終 tree に残る場合の適用順は base → selected variants → `propertyValues` → `slotContent` → public `allowedOverrides` とする。`propertyValues` は Variant 値を、public override は最終 tree 上の先行値を上書きできる。
- 1 Instance 内の複数 selected slots は、Definition base tree 上の target 同士が**同一 EntityID**、または一方が他方の strict ancestor / descendant なら Instance を不正として拒否する。判定は slot replacement より前に行い、slot 名、Dictionary 挿入順、replacement が空かどうかに依存させない。空配列も selected replacement である。この拒否後、同じ旧 descendant を消す selected slot は高々1つとなり、重複 owner の診断規則は不要となる。
- overlap のない selected slot が selected Variant または instance `propertyValues` の write target を Definition base tree 上の **strict descendant** として除去する場合は typed conflict として拒否する。slot target 自身は含めない。`allowedOverrides` はこの先行書込み conflict に含めず、slot 適用後の tree に対して評価する。public override が消えた path に書けば `unknownPath`、非公開 path なら `forbiddenOverride` とする。
- Resolver が返す最初の typed error の**phase 間**優先順位は、(1) unknown variant / property / slot や `forbiddenOverride` を含む Instance API validity、(2) selected Variant 同一 path conflict、(3) selected-slot target overlap、(4) selected prior write / slot conflict、(5) 実際の resolution と後段 `unknownPath` とする。同じ phase 内の複数不正について細かな first-error 順は固定しないが、決定的で fail closed とする。`conflictingVariants` と forbidden override が同時にある場合は `forbiddenOverride` を先に返す。この優先順位は Spike 当時の Resolver の first-error 順から変更した。DocumentValidator が他の診断も集める挙動を単一診断へ制限する決定ではない。
- `ComponentResolver.resolve` は1 Definition の tree を materialize し、nested Component Instance は参照 node のまま保持する。再帰的な component dependency と cycle safety は Document / ComponentAvailability validation の責務とする。
- cache key、実際の invalidation、variant explosion の閾値、局所再計算の latency はこの correctness Decision では決めない。Spike の 1,000 Instance 直接 resolve 時間、論理的な affected output set、異なる JSON shape 同士の保存 bytes 比較を production 性能・cache の保証として扱わない。

この Decision は [instance-resolution](spikes/instance-resolution/SPIKE.md)、[slot-write-conflict-boundary](spikes/slot-write-conflict-boundary/SPIKE.md)、[slot-conflict-priority](spikes/slot-conflict-priority/SPIKE.md) の Evidence に基づく。Spike 当時の Resolver では nested slot の名前順で silent discard と `unknownSlot` が分かれ、混合不正では `conflictingVariants` を `forbiddenOverride` より先に返していた。これらの挙動を保存せず、選択 slot の overlap 拒否と明示した phase priority を契約とした。同一 target ID の別 slot 名も Spike 当時の source では名前順の後の置換が勝っていたため、同じ overlap 禁止に含めた。この同一 target ケースは Spike 当時の source からの推論であり、3 Spike の raw fixture による実測ではない。

## Unknowns

この correctness Decision に属する Resolver、DocumentValidator、Canonical validation の実装と恒久 test は完了した。残る受入条件は整理・追加テスト commit の exact-SHA CI 検証と、削除前の最終監査である。ComponentInstance の Variant・property・slot 等を変更する GUI / CLI / AI AuthoringIntent は別の product work であり、この resolver correctness Decision の follow-up ではない。production cache / locality / end-to-end performance も今回の Decision 境界外の最適化であり、具体的な性能要件が生じ、独立した不可逆な判断が必要になった場合だけ別 ADR に分離する。現在の未実装・未計測範囲は [実装状況](../../docs/implementation-status.md) に示す。

## Required Evidence

[spikes/instance-resolution/SPIKE.md](spikes/instance-resolution/SPIKE.md) に direct Resolver の 16 ケース、Current Canonical sparse save、1,000 Instance の raw resolve cost / 論理 affected output set、独立監査を記録した。[slot-write-conflict-boundary Spike](spikes/slot-write-conflict-boundary/SPIKE.md) では selected write が slot 置換で消えても Canonical save が受理していた Spike 当時の挙動、test-only conflict membership、既存 error を隠す素朴な候補方式、valid nested Definition / cycle の validation 境界を記録した。[slot-conflict-priority Spike](spikes/slot-conflict-priority/SPIKE.md) は test-only 18ケース・Application 境界5ケース・独立監査を記録した。selected prior write を消す slot 名の全件集合は固定 fixture で導出できた。outer-first nested slot の Spike 当時の `unknownSlot` と混合 `conflictingVariants` / `forbiddenOverride` を先行判定が覆う反例は、上記 overlap 禁止と phase priority を明示する判断材料にした。実際の局所再計算と同一 encoding boundary での保存量比較は未検証のまま区別する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準と反例に照らして上記方式を選んだ。実装と恒久的なルールは Current Architecture と code/tests に反映した。exact-SHA CI と最終監査を確認し、[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Status

Implementation Required
