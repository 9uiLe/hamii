# Git CanonicalRevision profiling

2026-09-28、Apple M1 Pro、macOS 27、Swift 6.4 debug XCTest。分割 Canonical JSON を持つ一時 Git Repository で、`GitCanonicalRevisionCalculator.current(at:)` の現行経路を段階別に測定しました。`HAMII_GIT_ORACLE_PROFILE_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredGitOracleStages` で再測定できます。各 fixture 5回、p50 は中央値、p95 は5標本の最大値です。Fixture 作成、Index rebuild、対照となる unprofiled call は表の所要時間から除外しています。単一環境の mechanism evidence であり、Product SLA ではありません。[各 run の生データ](performance-data/git-oracle-stages-2026-09-28.json) を保持します。

## 実行経路

現行 oracle は `git status`、`git ls-files -v`、`git check-attr filter`、再度の `git status` を順に実行します。各 Git stage の時間は `Process` 作成・起動、子プロセスの完了、出力読込をまとめた wall time です。`total` には parse、working-tree bytes の読込と hash、Git subprocess、および小さな未分類 overhead が含まれます。`checkAttrInputPreparation` は `git check-attr --stdin` に渡す path bytes の構築のみで、同 subprocess の一時入力ファイル準備は `checkAttr` stage に含みます。

## 測定結果

表の値は **p50 / p95 ms**。すべての成功 sample は Git subprocess 4回でした。`tracked` は `git ls-files -v` が返した Canonical JSON 数です。`changed` は最初の `git status` が返した Canonical path 数です。

| Fixture | tracked / changed / working bytes hashed | status #1 | ls-files | check-attr | status #2 | total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 Component clean | 3 / 0 / 0 B | 85.58 / 97.30 | 85.91 / 92.54 | 83.64 / 90.26 | 91.75 / 96.56 | 349.86 / 363.36 |
| 1000 Components clean | 1002 / 0 / 0 B | 94.12 / 96.86 | 86.29 / 91.81 | 86.95 / 98.87 | 91.30 / 98.87 | 360.54 / 382.98 |
| 5000 Components clean | 5002 / 0 / 0 B | 99.59 / 99.64 | 83.23 / 85.11 | 91.09 / 93.15 | 91.11 / 93.84 | 383.23 / 383.32 |
| Mixed semantic clean | 24 / 0 / 0 B | 89.20 / 99.16 | 87.93 / 93.35 | 89.47 / 93.94 | 83.22 / 95.25 | 350.03 / 366.63 |
| 1 Component, dirty tracked | 3 / 1 / 697 B | 84.21 / 94.33 | 83.23 / 87.62 | 87.58 / 96.16 | 83.01 / 95.88 | 336.60 / 364.80 |
| 1 Component, untracked shard | 3 / 1 / 689 B | 86.14 / 95.52 | 85.42 / 88.44 | 88.19 / 96.49 | 88.32 / 98.66 | 353.72 / 369.54 |

| Fixture | tracked flags parse | attr input | attr parse | changed path sort | changed bytes read + hash | status #1 parse | status #2 equality |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 Component clean | 0.03 / 0.06 | 0.01 / 0.01 | 0.04 / 0.07 | <0.01 / <0.01 | <0.01 / <0.01 | 0.02 / 0.02 | <0.01 / <0.01 |
| 1000 Components clean | 1.62 / 3.15 | 0.34 / 0.46 | 2.30 / 4.51 | <0.01 / <0.01 | <0.01 / <0.01 | 0.02 / 0.03 | <0.01 / <0.01 |
| 5000 Components clean | 7.75 / 8.86 | 1.32 / 1.47 | 8.89 / 9.47 | <0.01 / <0.01 | <0.01 / <0.01 | 0.01 / 0.01 | <0.01 / <0.01 |
| Mixed semantic clean | 0.10 / 0.11 | 0.02 / 0.05 | 0.06 / 0.13 | <0.01 / <0.01 | <0.01 / <0.01 | 0.01 / 0.02 | <0.01 / <0.01 |
| 1 Component, dirty tracked | 0.03 / 0.08 | 0.01 / 0.02 | 0.03 / 0.07 | 0.01 / 0.01 | 0.19 / 0.40 | 0.02 / 0.04 | <0.01 / <0.01 |
| 1 Component, untracked shard | 0.03 / 0.06 | 0.01 / 0.01 | 0.06 / 0.08 | 0.01 / 0.01 | 0.32 / 0.47 | 0.03 / 0.03 | <0.01 / <0.01 |

同一 run 内の stage 時間を合算した結果も **p50 / p95 ms** で示します。各列の単独 p50 を足した値ではありません。

| Fixture | status #1 + #2 | ls-files + check-attr |
| --- | ---: | ---: |
| 1 Component clean | 180.10 / 189.04 | 170.74 / 182.80 |
| 1000 Components clean | 183.42 / 193.53 | 173.92 / 187.76 |
| 5000 Components clean | 189.92 / 193.43 | 174.33 / 177.20 |
| Mixed semantic clean | 177.70 / 178.73 | 173.16 / 187.29 |
| 1 Component, dirty tracked | 165.00 / 190.21 | 169.07 / 183.77 |
| 1 Component, untracked shard | 175.54 / 184.80 | 171.58 / 183.79 |

参考として同じ Mac で `/usr/bin/git --version` を Python subprocess から10回起動した wall time は p50 10.29 ms、最大 11.51 ms でした。実 Git command は約80–100 ms/回ですが、この参考値を各 command から引いて「純粋な Git 処理時間」とは解釈しません。Git repository 状態、argument、入出力、scheduler、cache が異なります。

## Correctness control と解釈

Profiling の ON/OFF で clean tracked、dirty tracked、untracked Canonical shard の `CanonicalRevision` は一致しました。`assume-unchanged`、`skip-worktree`、Git clean filter は両経路で `unverifiableSource` として拒否されました。最初と最後の status の間で branch を切り替える race は、両経路で `stale` として拒否されました。これらは `testGitOracleProfilingPreservesRevisionAndRejection` が検証します。

測定条件では4つの Git subprocess stage がほぼ同程度に大きく、clean fixture で working-tree bytes hash は発生しませんでした。5000 shard の tracked flags / attribute parse は合計およそ17 msで、約383 ms の total に対する主因ではありません。この結果は「どの safety check を省いてよいか」を示しません。特に二度目の status、hidden flag 検査、filter 検査は現在の fail-closed 判定に必要です。次の方式比較では、これらの保証を保ったまま subprocess cost を下げられるかを別途検証します。
