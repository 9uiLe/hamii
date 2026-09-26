# Current query projection dependency inventory

This inventory is derived from `Sources/HamiiIndex/IndexProjection.swift`,
`Sources/HamiiCore/Validation.swift` (`ScopeEvaluator` and
`ComponentAvailability`), and `Sources/HamiiIndex/LocalIndex.swift`. It is
source inspection, not a measured incremental reindex result.

| Derived rows | Current source inputs | Invalidation candidates |
|---|---|---|
| `components` identity, name, owner | ComponentDefinition ID, name, ownerScopeID | Changed/deleted ComponentDefinition |
| `components.usage_count` | All Screen layer trees' ComponentInstance definitionIDs | Changed Screen usage, including removal; count for referenced ComponentDefinition |
| `scope_closure` | ArchitectureScope ID and parentID transitive ancestry | Changed Scope and descendants |
| `component_availability` | Scope ancestry, ComponentDefinition ownerScopeID, availability policy, nested ComponentInstance dependencies in Definition roots and slot content | Changed Scope and descendants; changed Definition and reverse dependent Definitions; affected consumer Scope rows |
| `metadata` | Document ID, Document revision, CanonicalRevision | Every published generation |

The current SQLite projection has no token or asset usage tables. The
conceptual Token → Component → Screen probe does not prove token invalidation
for this production schema. Future query projections require their own
dependency inventory before incremental indexing can be considered complete.

The current projection is rebuilt as one SQLite transaction. It does not
publish separate generations, and this inventory does not establish a safe
source snapshot across external Git operations.
