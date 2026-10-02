# Nested slot conflict at the Application boundary

Evidence-only probe of Current `ComponentResolver`, `DocumentValidator`,
`CanonicalRepository`, and `ProjectService`. `Probe.swift` contains a small
test-only preflight detector; it is **not** a production rule or Application
Service integration. `result.json` retains each fixed case's raw outcomes.

## Reproduce

Source commit: `c43ea3179559d55049db4e98db4cf013e81b0588`.
Environment: macOS 27.0 arm64, Apple Swift 6.4. The probe links SwiftPM debug
objects after checking that source and package bytes match the source commit.
Each case creates and removes a temporary Canonical Repository outside the
checkout. No simulator, network, or Product build is used.

```sh
git diff --quiet c43ea3179559d55049db4e98db4cf013e81b0588 -- Package.swift Package.resolved Sources
test -z "$(git ls-files --others --exclude-standard -- Package.swift Package.resolved Sources)"
swift build --product hamii
swiftc -I .build/debug \
  adr/component-variant-resolution/spikes/slot-conflict-priority/artifacts/application-boundary/Probe.swift \
  .build/debug/HamiiFormat.o .build/debug/HamiiApplication.o .build/debug/HamiiCore.o \
  -o /tmp/hamii-slot-application-probe
/tmp/hamii-slot-application-probe > \
  adr/component-variant-resolution/spikes/slot-conflict-priority/artifacts/application-boundary/result.json
```

## Confirmed Current behavior

The fixed Definition has `outer_slot -> inner_slot -> old_text`. Its selected
`tone=active` Variant writes `old_text.text`. Both slots are selected in an
Instance. Resolver applies Variant writes first, then slot content by sorted
slot name.

| Case | Resolver / Validator | Canonical | Application observation |
| --- | --- | --- | --- |
| `a_inner` then `z_outer`, both nonempty | Success; old Text gone; no diagnostic | Accepted, reopened equal | Supported unrelated `createPage` accepted |
| `a_outer` then `z_inner`, both nonempty | `unknownSlot(z_inner)` after outer removed inner; `component.resolution@screen_instance` | Rejected; old Canonical bytes retained | No service mutation attempted |
| Inner empty, outer nonempty | Success; old Text gone; no diagnostic | Accepted, reopened equal | Unrelated `createPage` accepted |
| Inner nonempty, outer empty | Success; old Text gone; no diagnostic | Accepted, reopened equal | Unrelated `createPage` accepted |
| Variant unselected, both slots selected | Success; old Text gone, but **no selected Variant write** | Accepted, reopened equal | Unrelated `createPage` accepted |

In the primary case the test-only detector identifies both `a_inner` and
`z_outer` as selected slots whose *original Definition subtree* contains the
same Variant-written `old_text`. This is a logical conflict set, not proof of
which write was physically lost first. The actual current service accepts a
supported unrelated mutation on that valid persisted state. The service has
no intent to edit `ComponentInstance.variantSelection` or `slotContent`;
direct Canonical fixture setup above is separate from service mutation.

### Test-only preflight gate

Before invoking `ProjectService.mutate`, the probe checks its detector. For
the four selected-Variant cases the hypothetical gate would reject; for the
unselected-Variant control it does not. The probe **skips the service call**
at that point and compares the same observed state before/after: Canonical
JSON bytes, Document revision, and `ClientPrecondition` are all unchanged.
This verifies the test harness's no-call branch, not a production transaction
or race-safe precondition. It then separately invokes the existing service's
`createPage` on accepted Canonical cases: it succeeds, advances revision by
one, changes Canonical bytes, and issues a new precondition. No production
conflict gate was added.

The reverse-order invalid candidate fails at Canonical commit before any
service mutation. Its `canonicalBytesEqualBeforeAfterCommitAttempt` field in
`result.json` is true, recording actual Canonical JSON bytes rather than only
semantic reopen equality.

## Inference / remaining decision

An eventual common product rule could reject the primary selected-write
conflict before publishing a candidate, while allowing the unselected-Variant
control. This probe does not choose whether the rule should reject all
overlapping selected slots or only those erasing a selected prior write, how
to report multiple conflicts, or where the transaction boundary should live.
The reverse-order `unknownSlot` is already rejected by Current Resolver.

## Unknown / not implemented

- No production nested-slot conflict rule, application gate, or slot-edit
  intent exists. The test-only gate has no authority outside this probe.
- This run does not measure concurrency, cache invalidation, or performance.
- The unchanged-precondition gate result is only for a no-op preflight branch;
  it does not establish safety against another writer racing after preflight.
