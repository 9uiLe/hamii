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

**Tentative:** Git-reviewable Profile bytes plus explicit Product repository/source binding appear necessary. The placement and binding mechanism are undecided. A repository name alone is insufficient to establish authority.

## Unknowns

- Which placement reproduces the same mapping after checkout/branch switch and rejects stale Product source changes?
- What exact repository/source identity is practical without invalidating unrelated mapping changes on every Product commit?
- Can Profile writes and hamii-managed Git transitions be coordinated without creating a second inconsistent writer protocol?
- How does Profile v1 evolve independently of Document format, and what happens to existing external v1 files?
- Does any option make Product-specific symbols visible to Core IR or silently trust a wrong repository?

## Required Evidence

The [Storage Location and Binding Spike](spikes/storage-location-and-binding/SPIKE.md) compares the same Profile v1 under each placement. It must exercise checkout/branch switch, Product commit changes, mapping diffs, concurrent hamii save/Git transition, repository identity, malformed and missing inputs, and independent Profile versioning. Record what is observed separately from inferred guarantees.

## Decision Criteria

Choose only after an evidence commit preserves the Spike result. The selected boundary must keep Product mappings out of Core IR, fail closed on stale/wrong-repository input, make authority reviewable and replayable, preserve independent Profile versioning, and state the v1 compatibility/migration path. If Canonical, prove Snapshot/transaction/ClientPrecondition participation. If non-Canonical, prove its source identity binding. Put the decision in a later decision-only commit; Product source patching and runtime validation remain outside this ADR.

## Status

Spike Required
