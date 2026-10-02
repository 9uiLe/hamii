# Independent audit checklist: instance resolution

This checklist was fixed before reading the other probes' artifacts. It audits the
decision in [the ADR](../../../../ADR.md) against the current model and resolver;
it records questions and required evidence, not a selected implementation.

## Current source boundary

- `ComponentInstance` stores a Definition ID, variant selection, property values,
  slot content, and allowed overrides, without a copied Definition tree
  (`Sources/HamiiCore/Model.swift:206-216`). A Variant stores an axis/value and
  sparse text-path overrides (`Model.swift:466-473`). Owner Scope is on the
  Definition (`Model.swift:476-490`).
- `ComponentResolver.resolve` starts from the Definition root, applies selected
  Variants in sorted axis order, then property values, slots, and public path
  overrides (`Sources/HamiiCore/ComponentResolver.swift:23-57`). It rejects two
  selected Variants writing the same path (`:26-35`). It does not recursively
  materialize nested Definition instances or maintain a cache.
- `DocumentValidator` checks variant selection, public API keys, Resolver errors,
  nested slot children, Definition layer trees, and duplicate axis/value keys
  (`Sources/HamiiCore/Validation.swift:179-209,256-311`). Availability recursion
  checks nested Definition dependency and cycles separately (`Validation.swift:55-91`).

## Blind review gates

1. **No silent overwrite.** Use a base text path changed by two selected axes,
   including equal and unequal values. Assert a typed conflict rather than a
   deterministic last-writer result. Inspect collisions across Variant delta,
   exposed property value, public path override, and slot replacement. If a
   higher-priority layer intentionally wins, require an explicit precedence
   rule and a probe showing no accidental loss; sorted iteration alone is not
   a design justification.
2. **Precedence and validation.** Compare resolved trees and diagnostics for
   all relevant permutations of Variant declaration order and map insertion
   order. Cover unknown axis/value, duplicate axis/value declarations, missing
   target path, private override, unknown property/slot, and slot target kind.
   Check `DocumentValidator` and Canonical save rejection as well as direct
   Resolver throws; do not claim persisted-data safety from a direct throw.
3. **Nested Definitions.** Include at least A→B and A→B→A, plus nested slot
   content. Distinguish cycle/availability validation from recursive tree
   resolution: the current Resolver returns nested instance nodes unchanged.
   A claim that nested definitions are fully resolved needs a concrete tree
   oracle; a claim that cycles fail needs the actual validator/consumer path.
4. **Storage and update propagation.** Inspect Canonical bytes or encoded
   entities to show Instances keep references/deltas, not Definition subtree
   copies. After editing a Definition, compare all dependent resolved outputs;
   after editing one Instance, compare unaffected outputs. Record both changed
   entities and recomputed entities. A prototype invalidation graph is evidence
   for an option, not proof of a production cache or incremental writer.
5. **Performance evidence.** Identify fixture shape, number of definitions,
   axes, variants, paths, nesting, and instances. Separate single-instance
   resolution, 1,000-instance batch, validation, serialization, and cache or
   invalidation time. Record environment, source commit, cold/warm conditions,
   trial count, p50/p95/max and raw bounded results. A small synthetic 1k case
   cannot establish general project latency or a Product SLA.
6. **Authority boundary.** Component ownership and availability remain
   Definition-level architecture rules; Variant cannot silently change Scope.
   Distinguish `component.resolution` diagnostics from `component.denied`,
   `component.notAllowed`, or `component.cycle`. Confirm failed candidate
   validation has no Canonical save; note any derived or disposable side effect
   separately.

## Inputs required from the other probes

- Exact source commit, probe source and run command, bounded raw output,
  environment/toolchain, and any controlled fixture or temporary repository.
- Definition/Variant/Instance fixture data, expected resolved tree or independent
  oracle, typed error/diagnostic rows, and before/after Canonical entity bytes
  for storage claims.
- Explicit changed/recomputed/invalidated instance sets for update claims;
  trial arrays and measurement boundaries for performance claims.
- A list of untested cases and whether each reported result is Confirmed,
  Measured, Inferred, Unknown, or Not implemented.

The audit result will be appended after the independent probes are available.
