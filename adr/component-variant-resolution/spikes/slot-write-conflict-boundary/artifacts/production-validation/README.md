# Production validation at the slot-write boundary

This Evidence-only probe uses the Current `ComponentResolver`,
`DocumentValidator.validate`, and `CanonicalRepository.commit`/reopen. It does
not add a conflict rule or change production code. `result.json` is the raw
case matrix, including direct resolver output, typed validation rules,
Canonical commit outcome, reopen result, and actual Canonical JSON byte
comparison before and after each commit attempt.

## Reproduction

Source commit: `0376e79b1d9e1969cf3beaa5047dbd599bf79703`.
Environment: macOS 27.0, Apple Swift 6.4, arm64. Each case creates a separate
temporary Canonical Repository outside the checkout and removes it after
observation. The fixed fixture uses one `Panel` Definition with an outside Text,
a slot target Stack containing an inside Text and nested Stack/Text, one
`tone=active` Variant, public Text properties, and one Screen instance.

```sh
git diff --quiet 0376e79b1d9e1969cf3beaa5047dbd599bf79703 -- Package.swift Package.resolved Sources
test -z "$(git ls-files --others --exclude-standard -- Package.swift Package.resolved Sources)"
swift build --product hamii
swiftc -I .build/debug \
  adr/component-variant-resolution/spikes/slot-write-conflict-boundary/artifacts/production-validation/Probe.swift \
  .build/debug/HamiiFormat.o .build/debug/HamiiApplication.o .build/debug/HamiiCore.o \
  -o /tmp/hamii-slot-conflict-probe
/tmp/hamii-slot-conflict-probe > \
  adr/component-variant-resolution/spikes/slot-write-conflict-boundary/artifacts/production-validation/result.json
```

Exit 0 was followed by independent assertions over all 11 matrix cases and
both nested/cycle cases. The JSON is bounded; no large build logs are kept.

## Confirmed in these fixed fixtures

| Case | Direct Resolver | DocumentValidator | Canonical commit / reopen |
| --- | --- | --- | --- |
| Slot target container itself selected | Container retained, children replaced | No rule | Accepted; reopened equal |
| Selected Variant writes inside selected slot | Earlier Text write disappears; Resolver succeeds | No rule | Accepted; reopened equal |
| Property writes inside selected slot | Earlier Text write disappears; Resolver succeeds | No rule | Accepted; reopened equal |
| Property writes outside selected slot | Outside value survives | No rule | Accepted; reopened equal |
| Slot unselected, selected Variant writes inside | Inside value survives | No rule | Accepted; reopened equal |
| Variant unselected, slot selected | No Variant write occurs; slot replacement succeeds | No rule | Accepted; reopened equal |
| Selected slot is empty after inside Property write | Inside Text disappears; Resolver succeeds | No rule | Accepted; reopened equal |
| Variant writes a nested descendant below selected slot | Nested Text disappears; Resolver succeeds | No rule | Accepted; reopened equal |
| Allowed Override targets removed inside Text | `unknownPath` after slot replacement | `component.resolution@screen_instance` | Rejected; old Document remains |
| Allowed Override targets outside Text | Outside value survives | No rule | Accepted; reopened equal |
| Variant writes `slot_container.text` itself | `unknownPath`; container has no Text payload | `component.variantPath@variant_active`, `component.resolution@screen_instance` | Rejected; old Document remains |

The silent loss cases are direct Resolver success **and** accepted Current
Canonical state. A successful commit does not currently mean every selected
Variant/Property write remains visible after slot replacement. The selected
slot target itself remains present; replacement changes its children. A
write to the container's unsupported `.text` path is already rejected and is
not the silent-loss case. The `slot_unselected_selected_variant_inside_survives`
control **does select** the Variant; only its slot is unselected. The separate
`variant_unselected_slot_selected_no_write` control selects the slot but has
empty `variantSelection`, so it cannot be counted as a selected-Variant
conflict.

For both rejected slot cases, actual Current Canonical JSON files were byte
identical before and after commit attempt (787 bytes in each before/after
snapshot); the previously published Document also remained observable. The
snapshot includes `hamii.json`, `hamii-agent-profiles.json`, and Canonical
entity shards, excluding disposable `.hamii/` coordination files.

### Nested Component boundary

- Acyclic `A -> B` Definition dependencies yielded no validation rules; the
  Canonical candidate was accepted and reopened equal.
- Direct `ComponentResolver.resolve(A instance, definition: A)` returned an A
  tree that still contains a `componentInstance` node referring to B. It did
  not recursively inline B.
- Adding `B -> A` gave `component.cycle` at the Screen A instance and the two
  nested reference Layers. Canonical commit rejected the candidate; the
  previously published acyclic Document remained observable. Its Current
  Canonical JSON bytes were identical before and after rejection (4,041 bytes
  in each snapshot).

## Inference for a possible test-only conflict rule

If a future rule rejects writes that are later erased, this fixture supports
targeting **selected** slot replacement whose target subtree contains an
earlier selected Variant or Property Text write. That would reject the
selected-inside, empty-slot, and nested-descendant silent-loss cases above.
It should not reject a write outside the slot, a slot that was not selected,
an unselected Variant, or the container-only replacement with no earlier
write. The late
`allowedOverride` missing path and unsupported slot-target `.text` path are
already typed failures; they do not need to be called silent losses. This is
an inference from fixed cases, not a production rule or final architecture
decision.

## Unknown / not implemented

- No conflict detector for cross-stage writes has been implemented. The
  current production acceptance shown above is not a product endorsement.
- This probe does not cover all possible overlapping slots, repeated IDs in
  replacement content, multiple selected axes, or performance. Nested
  reference resolution depth is observed only for direct Resolver versus
  Document-level validation here.
- Process crash and power-loss durability are outside this test; accepted
  reopen means a normal close/reopen after a completed commit.
