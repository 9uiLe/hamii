# Repository Profile Persistence

## Context

`IntegrationProfileFile` currently reads a caller-selected Profile v1 file without changing it. `hamii integration plan` uses that file after checking the Document's independent `integrationProfile` version. No hamii-managed Profile writer or Product repository adapter exists. Product-specific mappings must remain outside Native-semantic IR, while a future adapter needs a reviewable, reproducible authority for the mappings it applies. The [Product Integration Contract ADR](../product-integration-contract/ADR.md) owns the contract and Product validation work; this ADR owns only Profile persistence, identity, and versioning.

## Decision to Make

Where should a Product-specific Repository Profile be persisted, and what repository/source identity and format-version boundary makes that Profile an authoritative, replayable input?

## Constraints

- Product model, route, reducer, file path, and mapping symbols must not enter hamii Core IR.
- Profile format version is independent of Document format version.
- Missing, malformed, stale, or wrong-repository mapping authority must fail closed.
- Mapping changes must be reviewable; a plan must identify the exact Profile and Product source state it used.
- Current Profile v1 files and the read-only CLI path have a defined migration or compatibility outcome. Runtime historical compatibility must not leak into Current Core.
- A hamii Canonical shard, if selected, participates in Snapshot identity, transaction, ClientPrecondition, and migration. A non-Canonical Profile needs another reproducible source identity.

## Options

1. Store a Profile in the hamii Canonical repository, for example a root JSON shard. Git shares it and hamii Canonical observation/save owns it.
2. Store a Profile in the Product repository. Git shares it with Product source and hamii reads it through a validated repository binding.
3. Keep caller-selected external files as the formal authority. The current reader remains read-only and callers supply a validated source/binding for every plan.
4. Treat `.hamii/` local-only state as a comparison control. It is not presumed to be a shared, reviewable authority.

## Current Hypothesis

**Tentative implementation hypothesis:** Start with conservative exact-commit invalidation. A future relevant-source identity might avoid documentation-only invalidation, but it cannot replace the exact-commit baseline without evidence that no stale Product source is accepted.

## Unknowns

- Production receipt issuance and verification against immutable Git object bytes and a hamii observation.
- Isolated Product patch publication and races after plan; these remain Product Integration implementation, not a guarantee from this placement decision.
- Profile migration candidate and cross-repository version mismatch handling.
- Measured frequency and UX cost of exact-commit false-positive invalidation; a narrower identity is not yet justified.
- Shallow histories, repository relocation, and remote/fork policy in the explicit Product repository selection flow.

## Required Evidence

The [Storage Location and Binding Spike](spikes/storage-location-and-binding/SPIKE.md) compares the same Profile v1 under each placement. The [Product Repository Binding Spike](spikes/product-repository-binding/SPIKE.md) tests an immutable-source receipt with dirty, wrong-repository, replay, and branch cases. Concurrent hamii save/Product Git transition and Product patch publication remain separate untested boundaries. Record what is observed separately from inferred guarantees.

## Decision Criteria

The selected boundary must keep Product mappings out of Core IR, fail closed on stale/wrong-repository input, make authority reviewable and replayable, preserve independent Profile versioning, and state the v1 migration path. Product source patching and runtime validation remain outside this ADR.

## Decision

**Persist the authoritative Repository Profile as a tracked regular file in the selected Product Git repository.** Its authority is the exact immutable Product commit and Profile blob used for planning, together with the exact hamii project observation that produced the semantic contract. The selected Product repository root is an explicit input, never inferred from `repositoryName` or a profile path alone. Product-specific symbols remain in the Product-owned Profile and Integration layer, outside hamii Core IR and Canonical shards. `.hamii/` and arbitrary external files are not shared Profile authorities.

The initial safe binding is conservative:

1. Select the Product repository root explicitly. Require a clean checkout for authoritative planning and reject missing, untracked, non-regular, or symlinked Profile files. Read Profile bytes from the selected commit's Git object, not from a later mutable path read.
2. A plan/review receipt identifies the selected Product source commit OID, tracked Profile path and blob OID, exact Profile bytes identity, Profile format version, and the hamii Canonical observation/precondition used to produce the contract. The logical Product source identity is the immutable commit contents. An exact clone at the same commit has equivalent planning input; selecting a destination worktree for a Product write remains an explicit, separately validated act. A path or remote URL alone is not source proof.
3. Reuse of a receipt requires the same hamii observation and selected Product commit/Profile bytes. A changed Product commit, even a documentation-only commit, fails closed and requires a new plan. This false-positive invalidation is accepted for the initial correctness boundary. A branch name change at the same commit does not invalidate immutable planning input. An old plan is **never** independent authorization to patch a live Product worktree after a transition.
4. A Product patch uses an isolated candidate based on the pinned Product commit and must revalidate both hamii and Product publication preconditions before publishing. The patch publisher, source-symbol validation, and concurrent Git write protocol are Product Integration work; the test-only receipt is not their implementation or proof.
5. `formatVersion` belongs to the Product-owned Profile and evolves independently of Document format. The Document's `versions.integrationProfile` is a consumer compatibility marker; unsupported or mismatched versions fail closed. A future Profile format upgrade is a reviewed Product Git migration, with matching hamii compatibility checked before a plan becomes usable. No historical Profile decoder enters Current Core.
6. Existing external Profile v1 files are read-only, non-authoritative planning inputs until an explicit reviewed adoption copies the exact valid v1 bytes into the Product repository and commits them. Once the Product-owned authority is implemented, Product patch planning requires that tracked authority; the arbitrary external path is not a permanent alternate writer/authority.

**Evidence and limits:** The [placement Spike](spikes/storage-location-and-binding/SPIKE.md) observed a reviewable Product mapping diff and branch replay, while showing that current CLI accepts source-changed or wrong-intended-target plans and that a hamii-root pseudo-shard is outside Canonical observation. The [binding Spike](spikes/product-repository-binding/SPIKE.md) observed a test-only exact-commit receipt reject the measured dirty, stale, wrong-history, symlink, and changed-hamii cases, and accept exact replay. Its documentation-only rejection is the accepted safety/UX tradeoff. Neither Spike implements production authority, Product symbol checking, or atomic Product patch publication. Three independent reviewers initially returned insufficient evidence, then supported this conditional decision after the second Spike. Their shared concern—test-only identity is not a production guarantee—is **accepted** as an implementation gate. The Canonical-shard alternative's simpler hamii-local transaction is **rejected for placement** because Product source identity would still require a separate cross-repository binding and Profile ownership would be split from the source it names. Remote/fork trust beyond exact source-content equivalence is **deferred** to explicit destination selection and Product publication validation; it must fail closed when identity is ambiguous.

## Implementation and Validation Required

- Issue a structured production receipt from the selected immutable Product commit and captured hamii observation; include exact Profile and source identities in plan output.
- Reject dirty, missing, malformed, wrong-version, wrong-source, symlinked, changed-Profile, and stale-hamii inputs before any Product modification. Preserve a machine-readable reason.
- Implement explicit external v1 adoption into a reviewed Product commit and independent format-version migration/compatibility checks.
- Validate replay, clone/fork/relocation/shallow behavior under the stated identity semantics, and race cases around plan/use. Keep Product patch publication in the Product Integration boundary.
- Update Current Architecture, CLI skills, tests, and samples only when the production path exists; current documentation must continue to describe the present read-only external CLI accurately until then.

## Status

Implementation Required
