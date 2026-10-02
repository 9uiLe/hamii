# ComponentResolver precedence and correctness probe

Run from the repository root:

```sh
HAMII_SOURCE_COMMIT=$(git rev-parse HEAD) sh adr/component-variant-resolution/spikes/instance-resolution/artifacts/precedence-correctness/run.sh > /tmp/hamii-component-resolution-result.json
```

The script creates an isolated temporary Swift package depending on this
repository's `HamiiCore`, runs the fixed `probe.swift` fixture, and removes the
temporary package. It exits nonzero if a case differs from its expected typed
result. `result.json` records one successful run: 16 of 16 cases, commit
`e5bcd56c9e953a6e8d79661b35396d1cddff15c3`, Swift 6.4, arm64 macOS 27.0.
This is a correctness probe, not a latency benchmark.

## Confirmed for this fixture

- A single selected variant writes its sparse text path. Two selected axes
  writing separate paths both apply. Two axes writing `layer_label.text` throw
  `conflictingVariants:layer_label.text`, including when they write the *same*
  value; the resolver does not silently choose one variant. The disjoint-axis
  probe constructs `variantSelection` in opposite insertion orders and reverses
  `Definition.variants`; the returned `Layer` trees compare equal, not merely
  their displayed text.
- The observed precedence is base tree → selected variants → instance
  properties → slot child replacement → allowed path overrides. The selected
  `size=large` value `Large` becomes `Property` after a property value, then
  `Override` after an allowed override. The Definition root remains `Default`.
- A property value targeting `layer_slot_text.text` applies before replacement
  of the slot's children. The resolved tree then contains `layer_replacement`
  and no `layer_slot_text`; the property write has no visible resolved target
  and resolution still succeeds. The same loss occurs when a selected variant
  writes that old child path. An allowed override of the same removed path
  occurs after slot replacement and throws `unknownPath:layer_slot_text.text`.
- Unknown variant/property/slot/path and forbidden override each produce the
  corresponding typed `ComponentResolutionError` case in `result.json`.
- The nested `component_nested` reference remains a `componentInstance` Layer
  in the returned tree. This direct `ComponentResolver.resolve` call does not
  recursively expand that other Definition.

## Boundaries

The fixture invokes `ComponentResolver.resolve` directly. It does not establish
whether `DocumentValidator` accepts every constructed Definition or Instance;
the deliberately bad API path is especially a resolver error probe. It does
not test Scope/capability checks, nested dependency cycles across Definitions,
cache invalidation, persisted bytes, target generation, or 1k-instance
scaling. The precedence observation describes current code behavior; whether
the silent property loss on slot replacement is acceptable remains the ADR's
decision. No prototype here is production code.
