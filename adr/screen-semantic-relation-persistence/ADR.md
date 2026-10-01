# Screen Semantic Relation Persistence

## Context

The Product Integration Contract decision requires a screen-level contract with typed semantic sources and relations. Current `Screen` owns a layer tree, navigation, and nonoptional typed semantic declarations. `IntegrationContract` extracts declared sources, outputs, and relations. A free `SemanticOutputKey` alone does not identify a concrete screen output. Current Canonical Document Format is v3; the Migration boundary contains adjacent 1→2 and 2→3 edges.

## Decision to Make

Where should screen-level typed semantic sources, outputs, and relations be owned and persisted in Current Canonical IR?

## Constraints

- hamii IR remains Product independent. Product symbols and Repository Profile mappings do not enter these declarations.
- Every relation output must resolve through a unique declared screen output to an existing binding/input anchor. Missing, duplicate, or dangling identities fail validation.
- v2 `textBinding` and `Interaction.states` do not imply visibility, nil behavior, transform, or a typed relation. Migration must not infer them.
- Current Core reads only v3. Historical v1/v2 repositories require an isolated reviewed migration path, and older v2 readers reject v3.
- `Document.versions.integrationProfile` is the independent Repository Profile version and must not be repurposed.
- CanonicalSnapshot identity, client preconditions, worktree transactions, and migration publication must observe every new Canonical byte.

## Options

1. **Screen shard ownership:** add Product independent declarations to `Screen` and persist them in `screens/<screenID>.json`.
2. **Screen-owned Canonical sidecar:** persist declarations in a separate Screen ID keyed Canonical shard, such as `integration/screens/<screenID>.json`, and extend every Canonical path and transaction boundary.

An external explicit profile file is a control for comparison, but it cannot be the sole source of Native-semantic IR.

## Current Hypothesis

Resolved by the decision below. Screen shard ownership has the smaller Canonical path, transaction, and identity change surface in the tested repository.

## Decision

**Adopt Option 1: Screen shard ownership.** Product-independent typed semantic sources, declared outputs, and relations belong to `Screen` and persist in its existing `screens/<screenID>.json` Canonical shard. A relation edit changes that Screen shard's Canonical bytes. The installed CanonicalSnapshot, ClientPrecondition, Git freshness, and transaction journal boundaries already include this path. The current v2 decoder discards unknown Screen fields, so production storage requires Document Format v3 and a strict reader/version gate; no semantic field may be written under the v2 marker.

The initial output anchor schema supports direct Screen-owned Layers and Component definition-owned Layers addressed through an ordered instance occurrence path. Each Component frame carries its instance Layer ID, expected definition ID, and root-to-instance Layer path in its owning Screen or raw definition; the final target carries definition-owned Layer ID and property. Validation must check both raw definition ownership and the tree produced by `ComponentResolver`. A resolved-only lookup can mistake slot-injected content for definition-owned output. Slot-injected output anchors are unsupported in the initial schema and must be rejected. Variant resolution must verify the resolved value and binding separately: the current Variant model changes text values, not bindings.

Missing or stale instance paths, wrong or missing definition, missing target, unsupported property, binding mismatch, duplicate output identity, duplicate physical anchor, and dangling relation references fail closed. Distinct physical outputs may share one semantic source. Anchors and declarations contain no Product Repository symbols; Product mappings remain in the Integration Profile.

The sidecar option isolates relation-only diffs, but the measured unregistered sidecar changed neither production Snapshot identity nor client token. To make it safe would require simultaneous extension of Canonical path enumeration, document ownership/orphan checks, transaction journal, Git freshness, and migration input. The available diff-isolation evidence does not justify this added durable protocol surface. The [layout Spike](spikes/canonical-layout-and-v3/SPIKE.md) records the concrete boundary comparison; the [Component anchor Spike](spikes/component-output-anchor/SPIKE.md) records repeated/nested instance and fail-closed anchor results.

## Unknowns

- The ownership decision and Current v3 implementation are complete. Validate the integrated cutover against the full local gate and exact pushed SHA Verify before evaluating ADR closure.
- Route composition and legacy pending recovery are tracked in [Migration Edge Composition](../migration-edge-composition/ADR.md).

## Required Evidence

[Canonical layout and v3 Spike](spikes/canonical-layout-and-v3/SPIKE.md) compared both layouts with test-only prototypes. It found that the current v2 decoder drops new Screen fields under a v2 marker, and an unregistered sidecar is invisible to Snapshot identity and client preconditions. It demonstrated direct-Screen anchor validation, candidate round-trip, v2 reader rejection of a v3 marker, and sequential v1→v2 plus test-only v2→v3 transformation. [Component output anchor Spike](spikes/component-output-anchor/SPIKE.md) then tested repeated and nested Component occurrences, Variant/slot resolution, invalid anchor rejection, and candidate contract projection using actual resolver code.

The strict Current v3 codec and `CanonicalRepository` require explicit Screen semantics and matching 3/3 markers. Current authoring creates `.empty` semantics, and the Screen shard participates in the existing journal, CanonicalSnapshot identity, ClientPrecondition, and strict save/reopen validation. Core validates direct and Component occurrence anchors against raw and resolved trees and rejects slot replacement that reuses a definition Layer ID. `IntegrationContract` extracts Current declarations and represents empty semantics as empty lists. The real 2→3 raw-byte edge adds empty semantics without inferring relations and preserves unrelated Canonical bytes. Both historical v1 and v2 sources prepare reviewed v3 candidates; final publication remains subject to the separate Migration Edge Composition decision and its validation gates.

Focused Current v3 codec, transaction, and repository tests passed 15/15; single-pass snapshot/error-boundary tests passed 7/7. The reviewed v1/v2 CLI migration path reached v3 and completed inspect, validation, and Query in the focused end-to-end test. Full gate and exact-SHA CI remain separate completion evidence.

## Decision Criteria

Ownership is decided from the measured existing Screen path coverage, sidecar observation gap, candidate semantic round-trip, occurrence-safe anchor validation, and candidate identity change when relation bytes are included. The chosen implementation must add production extraction/validation, strict v3 reader separation, and a noninventive v2→v3 edge. The reviewed v1→2→3 path and publication must pass the integrated verification in [Migration Edge Composition](../migration-edge-composition/ADR.md). Preserve the [Product Integration Contract decision](../product-integration-contract/ADR.md) and its `Needs Resolution` rule.

## Implementation Gates

- Screen semantics old/new bytes must participate in the existing Canonical transaction journal. Stop/recover tests at prepared, ready, individual shard apply, and manifest switch must recover relation bytes wholly to old or new state, with matching Snapshot identity and ClientPrecondition. These are implementation completion gates, not a reason to reopen the ownership decision.
- Production validation and contract extraction must reject all invalid anchors and relation references named in the Decision. Repeated and nested instances must remain distinct; slot-injected content remains unsupported.
- Current v3 must reject raw historical repositories until isolated migration completes. Migration must add no inferred relation. The separate Migration ADR decides edge composition and publication.

## Status

Implementation Required
