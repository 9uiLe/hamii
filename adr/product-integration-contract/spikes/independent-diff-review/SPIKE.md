# Spike: Independent diff review of existing profile integrations

## Related Decision

[Product Integration Contract](../../ADR.md) の contract 粒度を、生成者自身の判定に依存せず比較する。

## Hypothesis

既存の3つの最終差分を匿名・独立にレビューすれば、contract fidelity、既存 Product behavior の保持、修正負担を区別できる。方式の採否はこの Spike だけで確定しない。

## Questions

- I01–I11 の意味が source 上でどこまで満たされるか。silent guess / loss はあるか。
- I03 の system image 指定と既存 avatar behavior はどう両立しているか。
- I08–I11 は共通 fixture と差分から追跡できるか。追加情報が必要なら何か。
- 各差分の semantic / architecture / cosmetic correction と review 時間はどれだけか。

## Prototype Scope

固定済み Team MINO iOS `dca2202f4be21869190d19bbcf223eb8646a2acd` の3つの **final patch のみ** をレビューする。生成に参加していない3人の agent に、ランダム化した A/B/C を1件ずつ割り当てる。各 reviewer は新しい context で開始し、方式名・生成時の `RESULT.md`・他 reviewer の判定を受け取らない。レビュー完了後に A/B/C と方式を対応付ける。人間 reviewer はいないので Human correction は未計測と明記する。

## Out of Scope

新しい integration attempt、差分修正、production code/API 変更、Xcode gate 再実行、runtime visual/accessibility validation、方式の正式 Decision。

## Measurements

各 reviewer は I01–I11 の11セルすべてを `correct / partial / incorrect / unresolved / silently lost` のいずれかに分類し、source path/line を伴う根拠を記録する。別軸として I03 の contract fidelity と Product avatar preservation、semantic / architecture / cosmetic correction 件数、regression risk、unsupported assumption / silent guess、merge verdict（そのまま可／修正後可／reject）、開始・終了時刻と review wall time、I08–I11 の追跡に要求した追加情報を記録する。分類は fixture の字義と既存 Product semantics の双方を明示して判断する。

Review packets は共通 fixture、共通 repository convention extract、固定 source、allowed scope、匿名 final patch、固定判定ルールだけを含む。各 packet の patch SHA-256 を記録し、元の final patch と一致させる。結果と対応表は全 review が完了するまで reviewer へ開示しない。

## Success Criteria

匿名 A/B/C の全3件について、33セルが空欄なく source evidence 付きで判定される。silent guess/loss、I03 の二軸評価、修正件数・review time、追加情報要求、merge verdict が記録され、レビュー完了後に方式名を開示できる。

## Failure Criteria

reviewer が生成結果・方式名・他の review に汚染される、空欄/根拠のないセルを成功扱いする、self-review と矛盾する発見を丸める、Human correction を agent review から推定する、source-level review を runtime 保証へ拡張する。

## Result

2026-10-01、固定した [blind review protocol と対応表](artifacts/README.md) に従い、生成に参加していない3つの fresh agent context が匿名 A/B/C の最終差分を1件ずつレビューした。順番と方式名は全 review 完了後に開示した。外部 target と hamii production source は変更していない。3 patch の展開後 SHA-256 は既存 Spike の final patch とバイト一致した。各 reviewer は source audit だけを行い、既存 Xcode gate の結果を自分の検証結果として扱わなかった。

| Intent | A = graph | B = component | C = screen |
| --- | --- | --- | --- |
| I01 displayName | correct | correct | correct |
| I02 secondaryText | correct¹ | correct² | partial |
| I03 avatar | silently lost | partial | partial |
| I04 editProfile | correct | correct | correct |
| I05 spacing | correct | correct | correct |
| I06 avatarLabel | correct | correct | correct |
| I07 native navigation | correct | correct | correct |
| I08 normal | correct | correct | correct |
| I09 displayName binding | correct | correct | correct |
| I10 secondaryText binding | correct | correct | correct |
| I11 edit destination | correct | correct | correct |

各33セルの source path/line と理由は [A](artifacts/reviews/A.md)、[B](artifacts/reviews/B.md)、[C](artifacts/reviews/C.md) にある。`correct` の判定にも根拠がある。¹ A は I02 を `correct` と分類しつつ、Profile がまだ存在しない状態で `가입일 정보 없음` を表示することを semantic correction として挙げた。² B は I02 を `correct` とし、この empty-profile 問題を修正対象にしなかった。C は同じ問題を理由に I02 を `partial` とした。この不一致を平均や多数決で消さない。既存の no-profile behavior と nil `createdAt` の区別には source-level の追加監査が必要であり、Human review の代用にはならない。

| Blind ID / shape | I03 contract fidelity | Existing Product avatar preservation | Minimal corrections semantic / architecture / cosmetic | Review wall time | Merge verdict |
| --- | --- | --- | --- | --- | --- |
| A / graph | 指定 system image が patch にない。Reviewer は `silently lost` と分類 | 既存の色別 art と `.plain` fallback を保持 | 2 / 0 / 0 | 177 s | 修正後可 |
| B / component | nil avatar color に限って指定 symbol を使うため `partial` | nil 時の既存 `.plain` art を置換、その他の色別 art は保持 | 1 / 0 / 0 | 121 s | 修正後可 |
| C / screen | 指定 symbol は存在するが avatar 自体でなく常時 overlay のため `partial` | 既存 art に重ねて遮る可能性がある | 2 / 0 / 0 | 242 s | 修正後可 |

I03 は3方式とも fixture の字義と既存 Product の avatar semantics を両立できていない。A の `silently lost` は**差分だけ**を見た reviewer の分類である。生成者の [既存結果](../existing-profile-state/SPIKE.md) は graph の I03 未達を明示していたため、「過去の自己報告も失敗を隠した」とは結論しない。B と C は asset 値の扱いに無断の解釈があり、既存 Product behavior の退行リスクがある。3 reviewer は I08–I11 を共通 fixture・source・patch から追跡でき、追加の route/state 説明を要求しなかった。ただし screen contract 単体に States/dependency 専用 field がない点は、この共通 fixture を与えた review では解消しない。

**Reviewability と限界:** 全 reviewer が既存 `Profile` と reducer → coordinator → edit destination を source から追跡し、Architecture correction は0件とした。全 verdict は修正後可で、差分をそのまま merge 可とはしなかった。review time は3人が異なる patch を1回ずつ見た値であり、方式による因果的な時間差ではない。Human correction は未計測。新しい非 nil 日付、avatar の見た目/VoiceOver、edit destination の runtime は未検証。A/B/C の分類差は独立 review の有益なばらつきであり、どれか1つを正解として丸めない。

## Conclusion

独立 review により、3つの最終差分の contract fidelity と Product avatar preservation に具体的な差が見えた。同時に I03 の fixture と Product semantics の優先・変換ルールが未確定で、I02 empty-profile 判定も reviewer 間で異なる。方式の順位や採否をまだ決めない。Human correction が未計測であり、共通 fixture による States/dependency 補足も残るため、Product Integration Contract ADR は `Spike Required` を維持する。

## Artifacts

[artifacts/README.md](artifacts/README.md) に blind protocol、SHA-256、A/B/C 対応表、再現手順があり、[reviews/](artifacts/reviews/) に編集していない agent review を保存した。外部 target checkout と一時 packets は Repository 外に置いた。
