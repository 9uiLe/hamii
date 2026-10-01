# Component Output Anchor Spike

## Related Decision

[Screen Semantic Relation Persistence](../../ADR.md): whether Screen-owned typed semantics can refer to a unique, concrete output even when Component definitions are instantiated more than once.

## Hypothesis

**Test-only candidate:** a direct Screen Layer ID or an ordered Component occurrence path can anchor one existing text binding. Each path frame records the instance Layer ID, expected definition ID, and root-to-instance Layer path in the current tree. Resolving each frame through the selected Component instance should distinguish repeated definitions and nested instances without Product symbols.

## Questions

- Can two instances of one `ProfileHeader` definition expose the same internal Layer ID as separate physical outputs?
- Can a nested Component, selected Variant, and slot replacement be checked against the resolved tree while retaining definition ownership?
- Which missing, changed, ambiguous, duplicate, or slot-injected targets must fail closed?
- Can the candidate anchor round-trip and feed the existing `IntegrationContracts.make` output deterministically?

## Prototype Scope

Use test-only Swift candidate types and the actual `ComponentResolver`, `DocumentValidator` (through `IntegrationContracts.make`), and `CanonicalByteIdentity` function. The fixture has one Screen, two `ProfileHeader` instances sharing `card_label`, one nested `Badge` instance, a selected `size=large` Variant, direct text, and slot content. The prototype has no production Core, Format, CLI, or migration changes. Run `python3 adr/screen-semantic-relation-persistence/spikes/component-output-anchor/artifacts/run.py` from repository root.

## Out of Scope

Product binding mappings, a production v3 schema, slot-injected output ownership, output kinds other than text/button binding, production contract extraction, migration edge composition, power-loss proof, and Product performance. The current resolver cannot vary `textBinding` through a Variant; only text values change.

## Measurements

Record focused test count and failures; count invalid anchor cases. Check actual resolved values and bindings, exact contract inputs/typed fields, sorted-key encode→decode→encode bytes, and identity changes when candidate bytes are included in the supplied file set. This is a correctness experiment, not a latency benchmark. On macOS with Swift 6.4, the focused test command ran 4 cases with zero failures; XCTest execution was 0.007 seconds after compilation. This number is not production throughput.

## Success Criteria

- Direct, repeated-instance, and nested-instance anchors resolve uniquely through one validation/projection path.
- A bare definition Layer ID, wrong/missing frame or definition, wrong target/property/binding, duplicate physical target, and slot-injected or removed target are rejected.
- A selected Variant's resolved text and binding are observed separately; an invalid Variant fails. Slot replacement invalidates a removed definition-owned output.
- One semantic source may feed two distinct physical outputs. Candidate anchor and semantics survive Codable round-trip; changing one occurrence path changes candidate bytes and identity when those bytes are included.

## Failure Criteria

Any false acceptance of a wrong occurrence, duplicate physical output, or slot-injected content as definition-owned blocks this anchor candidate. A test-only projection must not be reported as production IR extraction.

## Result

**Measured:** Four focused XCTest cases passed, zero failed. The `ProfileHeader` fixture resolved `instance_left/card_label` to text `Large` and `instance_right/card_label` to `Default`; both retained `profile.name` as binding but had distinct physical anchors. The nested path `instance_left → nested_instance/nested_label` resolved `profile.nested`. The direct Screen text and both Component occurrences passed the same output/relation validator. Two outputs shared `source.name` without sharing one physical target.

Twelve individually invalid output candidates were rejected: bare definition Layer ID, empty occurrence path, missing instance, reversed path order, wrong definition, missing target, wrong property, wrong Layer kind, wrong binding, slot-injected Layer, removed slot default, and reversed nested path. Two additional duplicate cases rejected distinct output keys targeting the same physical anchor and one output key targeting two different anchors. An unknown Variant selection failed through the actual resolver. A default slot target was valid before slot replacement and rejected after it was removed. The selected Variant changed text, not binding; the prototype makes no claim about Variant-dependent bindings.

The test-only projection called production `IntegrationContracts.make`, which collected resolved inputs including slot content. It attached sorted candidate semantic sources and relations afterward. The flat production `inputs` list deduplicates binding strings and cannot itself identify an occurrence; it does not yet carry output declarations. Candidate semantics (including direct and Component anchors) survived sorted-key encode→decode→encode byte-for-byte. Altering one instance path changed candidate bytes and `CanonicalByteIdentity` when those bytes were explicitly supplied; this is not evidence that the current v2 Canonical reader stores or observes the candidate.

**Inferred design constraint:** each occurrence frame must be checked against both the raw definition path and the resolved tree. Resolved-only lookup could mistake slot-injected content for definition-owned content. A selected slot's replaced subtree is explicitly rejected; reuse of a definition Layer ID inside slot content still needs a focused adversarial test. The candidate stores structure only; it contains no Product symbol. Valid Variant text changes leave an unchanged binding anchor valid, while stale client observations remain the responsibility of `ClientPrecondition`.

## Conclusion

The tested occurrence-path candidate is sufficient to distinguish repeated and nested Component outputs in this fixture and rejects the tested invalid cases. This supports the Screen ownership decision but does not install a production schema, extraction path, or v3 reader. The persistence ADR remains **Spike Required** until the ownership/transaction boundary is decided with complete validation evidence. Migration edge composition has its own [ADR](../../../migration-edge-composition/ADR.md) and was not tested here.

## Artifacts

- [ComponentOutputAnchorSpikeTests.swift](artifacts/ComponentOutputAnchorSpikeTests.swift): test-only candidate schema, resolver/validator, fixture, invalid matrix, and projection/identity checks.
- [run.py](artifacts/run.py): focused runner that removes the temporary test-target copy after the test.
