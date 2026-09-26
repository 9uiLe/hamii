# 一貫した CanonicalSnapshot の取得境界

## Related Decision

[Index consistency ADR](../../ADR.md) の Canonical source observation と generation の入力保証。Writer の許可・分離・merge は [External Git Write ADR](../../../git-external-write-coordination/ADR.md) の別 Decision Boundary。

## Hypothesis

**Tentative:** hamii-owned GUI / CLI writer が `.hamii/write.lock` を協調して使用する範囲では、load/save と Snapshot acquisition を同じ coordination boundary に置ける。非協調の同一 worktree writer まで read/re-hash だけで atomic multi-file snapshot を保証することはできない。Immutable Git object は一貫した committed tree を提供しうるが、hamii が現在読む working Canonical Data と一致する条件が別に必要。

## Questions

- `CanonicalSnapshot` が何を所有するか。候補は identity / revision、正確な Canonical path と bytes、source metadata、取得時の observation guarantees。
- `CanonicalRepository.load` / `.hamii/write.lock` / journal recovery と snapshot の間にどの保証が成立するか。
- Immutable copy を作る間に external writer が変更したとき、混在した入力をどう拒否するか。
- Pinned Git tree を現在の working Canonical Data と同一視できる条件は何か。staged / unstaged / untracked / filter / hidden flags をどう扱うか。
- Branch switch / pull と snapshot acquisition が交錯した場合、abort / stale / retry のどれが安全か。
- APFS 等の filesystem/platform primitive で whole Canonical set の atomic observation が可能か。適用範囲・権限・コストは何か。

## Prototype Scope

同じ Canonical fixture を、hamii-owned coordinated read/save、temporary immutable copy、pinned Git object/tree、working-tree observation + invalidation、利用可能な filesystem primitive 候補で比較する。変更が起きる barrier を read/copy の前・途中・後に置き、`CanonicalSnapshot → CanonicalRevision → IndexProjection` に渡す contents が一貫しているかを確認する。最初は current `CanonicalRepository` と disposable Git repositories を使う。

## Out of Scope

非協調 writer を同一 worktree の安全な collaboration path として認めること、特定 fingerprint algorithm の採用、Production snapshot module の実装、External Git Write ADR の merge policy 決定。

## Measurements

各候補の保証対象 writer、source の範囲、拒否条件、混在 snapshot 件数、取得 p50/p95、file/shard 数と bytes、copy/clone storage cost、branch switch / external edit / Git filter / hidden flag の結果。Snapshot acquisition のみの時間と end-to-end Index 時間を分ける。

## Success Criteria

候補ごとに「何を同一時点の Canonical Data と呼べるか」を検証でき、保証外なら Projection に渡す前に拒否する。取得した exact contents から revision を導出し、同じ contents を Projection に渡せること。Non-coordinated writer に対して証明できない保証は主張しない。

## Failure Criteria

2回の同じ digest を atomic snapshot と誤認する、working bytes と異なる Git object を current と扱う、または混在した Canonical contents を検出不能なまま publish する。

## Result

| Candidate | What is guaranteed by current evidence? | Main unresolved condition |
| --- | --- | --- |
| hamii-owned writer coordination | `.hamii/write.lock` を守る save/load 間では途中 Document を読まなかった | lock を守らない external writer、snapshot の lifetime |
| temporary immutable copy | copy 完了後の destination bytes は固定できる | copy 中の external writer が混在入力を作る反例あり |
| pinned Git object/tree | pin した committed tree は branch switch 後も同じ bytes | staged / unstaged / untracked / filter と working Canonical contents の対応 |
| worktree observation + invalidation | current guard は検証不能な hidden/filter 状態を拒否 | 観測そのものは atomic multi-file snapshot を作らない |
| filesystem/platform primitive | 未検証 | whole-set atomicity、API availability、権限、latency |


**Confirmed, coordinated hamii writer only:** [focused XCTest](../../../../Tests/HamiiTests/CanonicalSnapshotSpikeTests.swift) は `CanonicalTransaction` が page file を適用して manifest を適用する前に停止し、別 `CanonicalRepository.load` が `.hamii/write.lock` で待つことを確認した。save 完了後、reader は新しい Document 全体を読み、途中状態を返さなかった。これは lock を尊重する hamii↔hamii の1 interleaving であり、外部 editor / Git process は lock を尊重しない。

**Confirmed, pinned Git object scope:** [disposable Git probe](artifacts/git_tree_probe.py) で commit A の object ID を pin すると branch B へ切り替えた後も A bytes を読めた。一方、B の tracked file を C へ staged/unstaged edit しても HEAD tree は B、untracked Canonical JSON は tree に存在しなかった。Immutable committed tree はその tree の一貫した入力だが、現在の working Canonical contents の snapshot とは一般には同一でない。Git clean filter で transformed representation と working bytes が異なる反例は [Concurrent Git mutation Spike](../concurrent-git-mutation/SPIKE.md) に記録済み。

**Confirmed, temporary copy boundary:** 非協調 writer が A=0/B=0 を A=1/B=0、A=1/B=1 の順に変更する間、A を先に B を後に copy すると、immutable destination は A=0/B=1 を保持した。この組合せは source に同時点で存在しなかった。Destination の immutable 性は acquisition の一貫性を作らない。Clean な小 JSON file の sequential copy は8 files / 40-run p95 **1.83 ms**、1000 files / 10-run p95 **216.75 ms**（Python `shutil.copytree`、実 Canonical parser や fsync なし）。この cost と混在反例は candidate の一条件であり、hamii lock 下または filesystem primitive の性能ではない。

**Confirmed failure evidence:** [Low-cost freshness Spike](../low-cost-freshness/SPIKE.md) の制御された2 file interleaving では、2回の full-byte scan digest が一致しても、その digest の表す組合せが存在しなかった。したがって multi-file copy 後の再読込や二重 hash だけを consistency proof としない。

**Inferred, not measured here:** temporary copy を lock 下で作れば hamii-owned writer の interleaving は防げるが、arbitrary external writer の途中変更は防げない。worktree observation + invalidation は fail-closed detection に使えるが、単独では exact atomic snapshot を作らない。Filesystem/platform primitive の whole-set guarantee、cost、権限は未調査。

## Conclusion

`CanonicalSnapshot` を revision より先に置き、exact contents と observation guarantee を明示する必要がある。hamii-owned coordination と pinned Git tree は保証範囲が異なる。現在の working tree に非協調 writer を許す場合の coherent snapshot acquisition は **Unknown**。どの候補も最終採用しない。検証不能なら既存の `staleIndex` 拒否を維持する。

## Artifacts

- [CanonicalSnapshotSpikeTests.swift](../../../../Tests/HamiiTests/CanonicalSnapshotSpikeTests.swift)、[coordinated-lock-result.json](artifacts/coordinated-lock-result.json): hamii-owned save 中の reader lock barrier。`HAMII_SNAPSHOT_SPIKE_RESULT=adr/index-consistency/spikes/consistent-canonical-snapshot/artifacts/coordinated-lock-result.json swift test --filter CanonicalSnapshotSpikeTests` で再測定できる。
- [git_tree_probe.py](artifacts/git_tree_probe.py)、[git-tree-result.json](artifacts/git-tree-result.json): pinned object と staged / unstaged / untracked working data の比較。
- [temporary_copy_probe.py](artifacts/temporary_copy_probe.py)、[temporary-copy-result.json](artifacts/temporary-copy-result.json): 非協調 writer 下の混在 copy と clean file copy p50/p95。
- [Low-cost snapshot result](../low-cost-freshness/artifacts/snapshot-result.json): 二重走査の存在しない複数 file 状態の反例。
