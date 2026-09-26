# External writer interleaving during Canonical save

## Related Decision

[External Git writes during Canonical save](../../ADR.md) の非協調 writer に対する保存保証を判断する Evidence。

## Hypothesis

旧新 bytes の journal と apply 前の content check だけでは、check と atomic replace の間に同じ file を書く非協調 writer の bytes を守れない。

## Questions

外部 edit が check 前、check 後の replace 前、replace 後に入る場合、どの bytes が残るか。journal recovery は後から消えた外部 bytes を復元できるか。

## Prototype Scope

APFS 上の一時 JSON file と barrier 付きの 2 writer で 3 通りの順序を再現する。journal は旧新 bytes だけを持つ単純模型とし、hamii の production code は変更しない。

## Out of Scope

Git checkout/pull の全手順、semantic merge、file coordinator の採用、production transaction code への patch。

## Measurements

各順序での最終 bytes、外部 bytes の残存、旧新 journal からの復旧可能性。事前 gate は外部 bytes を失う試行 0 件。macOS/APFS と command を記録する。

## Success Criteria

非協調 writer の bytes が全順序で残るか、失われた bytes を journal から特定して復旧できる。

## Failure Criteria

どの順序でも外部 bytes が黙って消え、旧新 journal から復元不能になる。

## Result

macOS 26.2 / APFS の一時 JSON file で旧新 bytes journal と content check → atomic replace を模した。外部 edit が check 前に入ると conflict で bytes を保持し、replace 後に入ると外部 bytes が残った。check と replace の間に入ると、guard は旧 bytes を読み、最後は hamii bytes となって外部 bytes は消えた。journal は旧新 bytes のみなので消えた外部 bytes を復元できない。事前 gate の 0 件に対し 1 / 3 順序で loss を観測した。これは production transaction の全 interleaving の測定ではなく、非協調 writer の race window を示す最小再現である。

## Conclusion

content check と atomic replace の組だけでは、非協調 external writer の bytes 保護を保証できない。外部 Git operation を hamii の協調境界に入れるか、競合を持ち込まない staging / merge protocol の成立条件を次の Spike で検証するまで ADR の判断を保留する。現在の実装は process crash に対する recovery を保証するが、非協調同時書込の lossless 保証は持たない。

## Artifacts

- [probe.py](artifacts/probe.py): barrier 付き書込の再現 script。
- [result.json](artifacts/result.json): 3 順序の結果。
