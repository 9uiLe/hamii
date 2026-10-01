# Screen Semantic Relation Persistence

## Context

The Product Integration Contract decision requires a screen-level contract with typed semantic sources and relations. The current `Screen` stores a layer tree and navigation, while `IntegrationContract` can represent optional typed relations that the current IR cannot extract. A free `SemanticOutputKey` does not identify a concrete screen output. The current Canonical Document Format is v2, and its migration registry has only a v1→v2 edge.

## Decision to Make

Where should screen-level typed semantic sources, outputs, and relations be owned and persisted in Current Canonical IR?

## Constraints

- hamii IR remains Product independent. Product symbols and Repository Profile mappings do not enter these declarations.
- Every relation output must resolve through a unique declared screen output to an existing binding/input anchor. Missing, duplicate, or dangling identities fail validation.
- v2 `textBinding` and `Interaction.states` do not imply visibility, nil behavior, transform, or a typed relation. Migration must not infer them.
- Current Core reads only Current Format. v3 requires an isolated migration path from both v2 and v1 repositories, and older v2 readers must reject v3.
- `Document.versions.integrationProfile` is the independent Repository Profile version and must not be repurposed.
- CanonicalSnapshot identity, client preconditions, worktree transactions, and migration publication must observe every new Canonical byte.

## Options

1. **Screen shard ownership:** add Product independent declarations to `Screen` and persist them in `screens/<screenID>.json`.
2. **Screen-owned Canonical sidecar:** persist declarations in a separate Screen ID keyed Canonical shard, such as `integration/screens/<screenID>.json`, and extend every Canonical path and transaction boundary.

An external explicit profile file is a control for comparison, but it cannot be the sole source of Native-semantic IR.

## Current Hypothesis

**Tentative, not a decision:** Screen shard ownership may require fewer new Canonical path, transaction, and identity rules. Output anchoring and v1→Current migration composition must be demonstrated before selecting it.

## Unknowns

- Which output declaration shape gives a stable, unique link to an existing binding/input without coupling to Product code?
- Which layout yields exact semantic round-trip and complete contract projection with the smaller durable transaction surface?
- What validation and migration runtime boundaries must change together for Current Format v3?

## Required Evidence

[Canonical layout and v3 Spike](spikes/canonical-layout-and-v3/SPIKE.md) compared both layouts with test-only prototypes. It found that the current v2 decoder drops new Screen fields under a v2 marker, and an unregistered sidecar is invisible to Snapshot identity and client preconditions. It demonstrated direct-Screen anchor validation, candidate round-trip, v2 reader rejection of a v3 marker, and sequential v1→v2 plus test-only v2→v3 transformation. [Component output anchor Spike](spikes/component-output-anchor/SPIKE.md) then tested repeated and nested Component occurrences, Variant/slot resolution, invalid anchor rejection, and candidate contract projection using actual resolver code. These are evidence, not a production format decision. Production schema, complete validation/extraction, and journal recovery remain unproven. Migration path composition is tracked separately in [Migration Edge Composition](../migration-edge-composition/ADR.md).

## Decision Criteria

Select an ownership model only after evidence demonstrates unique output anchors, fail-closed references, exact semantic round-trip, complete extraction into the screen contract, Canonical identity change on a relation edit, strict v2/v3 reader separation, and explicit crash/journal boundary changes. A noninventive v2→v3 edge and safe v1→Current path remain implementation prerequisites; the independent composition/publication decision belongs to [Migration Edge Composition](../migration-edge-composition/ADR.md). Preserve the [Product Integration Contract decision](../product-integration-contract/ADR.md) and its `Needs Resolution` rule.

## Status

Spike Required
