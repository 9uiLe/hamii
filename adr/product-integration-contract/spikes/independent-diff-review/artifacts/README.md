# Blind review evidence

The three reviewers were new agent contexts and did not generate the patches. Each received one packet with the same [I01–I11 fixture](../../existing-profile-state/artifacts/profile-header-fixture.json), [target convention extract](../../existing-profile-state/artifacts/repository-profile.md), clean Team MINO iOS source at `dca2202f4be21869190d19bbcf223eb8646a2acd`, one anonymous final patch, and the fixed review instructions below. The packet did not contain a contract shape name, generator `RESULT.md`, self-review, or another review. The reviewers were instructed not to read those materials. This is an agent review, not a Human review.

The A/B/C mapping was drawn with Python `secrets.SystemRandom().shuffle(["screen", "component", "graph"])` at 2026-10-01 11:30:01 UTC, before the three reviewers started. Mapping and exact decompressed patch bytes were not disclosed to a reviewer until all reviews had completed. The reviewer start times were 11:30:34, 11:30:34, and 11:30:36 UTC.

| Blind ID | Revealed shape and original patch | Decompressed final patch SHA-256 | Raw independent review |
| --- | --- | --- | --- |
| A | [graph](../../existing-profile-state/artifacts/attempts/graph/final.patch.gz) | `22af1786da5a3c7200a8a6857c020224bf46f54111f38aa09aa2ae51cd770dd6` | [A.md](reviews/A.md) |
| B | [component](../../existing-profile-state/artifacts/attempts/component/final.patch.gz) | `576d5c465d7f07e581b5da7e7f2032cfe1b88d70b8fa0a2f6ae3a41eb3c4ee53` | [B.md](reviews/B.md) |
| C | [screen](../../existing-profile-state/artifacts/attempts/screen/final.patch.gz) | `8fa5eeb65aeec216f642fcb592a0c621b59841944e1d1e32c637f9752998dff7` | [C.md](reviews/C.md) |

The patch bytes came from the corresponding `existing-profile-state/artifacts/attempts/<shape>/final.patch.gz`. SHA-256 and byte equality were rechecked after each review. The temporary packet path in raw reviews was `/tmp/hamii-integration-spike/independent-review/packets/<blind-id>/final.patch`; a fresh reader can recover identical bytes by decompressing the linked `final.patch.gz` and comparing the hash above. Patch line citations in the reviews refer to those decompressed bytes. Team MINO source citations refer to the pinned clean checkout unless a reviewer explicitly says `proposed`.

## Fixed instructions given to each reviewer

Review only the packet and the clean pinned source. Do not read hamii ADRs, other packets, generator `RESULT.md`, self-review, or another review. Do not change target source. Classify each I01–I11 as exactly one of `correct`, `partial`, `incorrect`, `unresolved`, `silently lost`, with source path and line evidence. `correct` also needs evidence. Distinguish fixture fidelity from preservation of existing Product semantics; assess I03 on both axes. For I08–I11 say whether fixture, source and patch suffice, and name any additional information needed. Count minimum semantic, repository architecture/convention and cosmetic corrections separately. Record unsupported assumptions or silent guesses, Product regression risks, merge verdict (`merge as is`, `merge after fixes`, `reject`), start/end UTC and wall time. This is source audit only; runtime outcomes are unknown.

No reviewer modified the source or ran the Xcode gate. The previous Spike's 30-test gate remains prior evidence, not a result of this review.
