# Spike: Component Variant と Instance の解決

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 06 Component Variant に対応。

## Hypothesis

base tree + sparse deltas + typed override precedence で 1k instance を局所的に解決できる。

## Questions

定義変更は全 instance に伝わるか。単一 instance 更新は局所的か。衝突や cycle を診断できるか。

## Prototype Scope

Current `ComponentResolver.resolve` を直接呼ぶ固定 fixture で、複数 axis、重複 path、property / slot / allowed override の順序、nested Instance の戻り値を観測する。別の 1,000 Instance fixture では Current `CanonicalRepository` へ sparse Document を保存し、直接 resolve の時間、出力差分集合、保存 bytes を測る。production cache は作らない。

## Out of Scope

Figma の全 variant UX、production source の全 target 対応。 試作 code をそのまま production code に昇格させない。

## Measurements

対象 source は `e5bcd56c9e953a6e8d79661b35396d1cddff15c3`。macOS 27.0 arm64 / Apple M1 Pro / Swift 6.4。正しさは固定 16 ケースの直接 Resolver 呼び出し。時間は 7 Layer Definition、1 axis、1 property、1,000 Instance の直接 resolve を 5 warmup 後 40 interleaved trial で測り、nearest-rank p95 を用いる。fixture 作成、Canonical save、JSON encode は計時外。raw 値と再実行コマンドは各 artifact に記録する。

## Success Criteria

subtree copy なし、定義変更の反映と局所 instance 更新が正しく、競合を拒否できる。

## Failure Criteria

局所変更が全 document 再解決を要する、または override 競合を黙って上書きする。

## Result

### Confirmed: fixed correctness fixture

Current Resolver の固定 16 ケースはすべて期待した値または typed error になった。単一 axis の sparse delta は base を変更せず text path を更新した。異なる path を変更する 2 axis は、selection の挿入順と Variant 配列順を変えても同じ resolved Layer tree になった。同じ path を変更する 2 axis は値が同じでも異なっても `conflictingVariants(path)` で拒否された。unknown variant / property / slot / path と非公開 override は typed error になった。

現行の適用順は base → selected variants → `propertyValues` → `slotContent` → `allowedOverrides`。同一 path では後段の instance property と allowed override が先の値を上書きした。slot replacement は、先に property または Variant が変更した旧 child を消しても Resolver が成功し、変更は結果から消えた。slot 後にその旧 path を allowed override が触ると `unknownPath` になった。これは現行挙動の観測であり、採用すべき precedence の決定ではない。nested Component Instance は参照 node のまま返り、直接 Resolver は他 Definition を再帰的に materialize しない。cycle / availability validation は別の境界であり、この probe はその成否を証明しない。

この 16 ケースは直接 Resolver を一回実行した結果であり、DocumentValidator がすべての fixture を受理することや Canonical save 時の同じ診断を保証しない。

### Measured: 1,000 Instance fixture

Current CanonicalRepository への sparse Document 保存は成功し、DocumentValidator diagnostics は 0。固定 fixture の出力差分集合は、Instance 500 の property 変更で `{500}`、共有 Definition の detail 変更で `{0…999}`。これは全件を再解決して比較した**論理的な影響集合**であり、production cache の invalidation や latency の実測ではない。

| Direct resolve | Trials | p50 | p95 | max |
| --- | ---: | ---: | ---: | ---: |
| 1 Instance | 40 | 0.009875 ms | 0.010500 ms | 0.020292 ms |
| 1,000 Instances sequentially | 40 | 8.703459 ms | 8.734084 ms | 8.768791 ms |

Current sparse Canonical JSON 全体は 655,792 bytes、Screen shard は 652,141 bytes。比較用の test-only materialized resolved subtree 1,000 個は 1,984,120 bytes、materialized Screen JSON は 2,657,591 bytes（疎な Screen shard bytes との数値比で約 4.08）。後者は汎用 `JSONEncoder` が異なる entity shape を符号化したもので、Current Canonical schema でも production write path でもない。したがって 4.08 を Canonical 保存量の削減率として扱わない。

初回の scale probe は macOS の `/var` と `/private/var` の path 正規化漏れで、計時前に exit 133 で停止した。修正後の 40 trial のみを上表に含める。root による再実行では、correctness JSON が完全一致し、scale fixture・影響集合・保存 bytes が一致した。再実行の時間値は上表に混ぜない。

## Conclusion

1,000 Instance の保存 fixture は Definition subtree を Instance 内へ複製せずに Current Canonical Data として保存できた。別の正しさ fixture では、同一 path の selected Variant 衝突を拒否した。一方、slot replacement により先行する property / Variant の変更が診断なしに消え、Failure Criteria の cross-stage silent loss が観測されたため、現行 precedence 全体を仕様として承認できない。nested Definition の再帰解決と cycle 拒否も直接 Resolver の測定範囲外。ADR は **Spike Required** のままとし、slot と公開 API path の関係、DocumentValidator / Canonical save における衝突拒否、nested resolution の decision boundary を追加検証する。cache hit 率、actual invalidation latency、product end-to-end latency は未測定である。

## Artifacts

- [Precedence and correctness probe](artifacts/precedence-correctness/README.md): fixture、16 ケース、raw JSON、再実行 script。
- [Scale and locality probe](artifacts/scale-locality/README.md): Current Canonical save、40 trial raw 値、保存 bytes、affected output indices、再実行手順。
- [Independent blind audit](artifacts/blind-audit/CHECKLIST.md) と [audit result](artifacts/blind-audit/AUDIT.md): 結果を読む前に固定した監査項目と、probe / raw JSON / production source に対する検証。
