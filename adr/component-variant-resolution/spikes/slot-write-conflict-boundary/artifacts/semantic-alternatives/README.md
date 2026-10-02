# Slot write conflict semantic alternatives

From the repository root:

```sh
HAMII_SOURCE_COMMIT=$(git rev-parse HEAD) sh adr/component-variant-resolution/spikes/slot-write-conflict-boundary/artifacts/semantic-alternatives/run.sh > /tmp/hamii-slot-conflict-result.json
```

The script creates a disposable Swift package depending on the current
`HamiiCore`, runs `probe.swift`, and removes the package. It exits nonzero if
any expected result differs. `result.json` is one run against commit
`0376e79b1d9e1969cf3beaa5047dbd599bf79703`, Swift 6.4 on arm64 macOS 27:
13/13 matrix cases and all structural relation controls passed. There is no
latency measurement. The first prototype run failed four no-conflict cases
because its test-only `conflictReject` branch lacked a no-conflict fallback;
that probe bug was fixed and the complete matrix rerun. It did not reveal a
production resolver failure.

## Three compared semantics

| Candidate | Meaning in this probe |
| --- | --- |
| `sequential` | Calls the current `ComponentResolver.resolve` unchanged. |
| `slotWins` | Test-only preflight removes selected variant/property/allowed override writes to old children of a replaced slot, then calls the current resolver. Suppressed writes are explicit in the result. |
| `conflictReject` | Test-only preflight emits `slotWriteConflict(path,slotName)` for such a write; otherwise calls the current resolver. This is **not** a production `ComponentResolutionError` case. |

The fixture has nested `outer` and `inner` slots, one old text child, an outside
sibling, selected and unselected variants, public properties and overrides.
Preflight conflict membership is a **strict descendant** of a selected slot
target in the Definition tree. For two selected nested slots, the prototype
chooses the nearest target (`inner`) for its diagnostic. That tie break is not
a product decision.

## Confirmed observations

- With a selected variant or property writing the old child, current sequential
  resolution succeeds and the write disappears after empty or nonempty slot
  replacement. The slot-wins prototype explicitly suppresses it; the reject
  prototype emits `slotWriteConflict(layer_old_text.text,outer)`.
- An allowed override to the old child runs after slot replacement. Current
  sequential resolution throws `unknownPath:layer_old_text.text`; slot-wins
  suppresses it; conflict-reject reports the same typed slot conflict as for
  the earlier writes.
- Unrelated sibling writes and writes from an unselected variant do not trigger
  the prototype conflict check. Clean slot replacement succeeds for all three
  strategies.
- Replacing the nested inner slot reports `inner`; replacing outer reports
  `outer`. If both are selected, the test-only nearest-target choice reports
  `inner`. Structural controls record target-to-self distance 0,
  outer-to-inner 1, outer-to-old-child 2, and no outer-to-outside relation.
  The target itself is excluded from conflict membership.
- A text write to the slot target itself is **not a legal current operation**:
  current slots target stack/overlay/scroll containers, whereas current
  `ComponentResolver` writes only text/button `.text` paths. All three probes
  return `unknownPath:layer_outer_slot.text`. The strict-descendant predicate
  excludes that exact target, but this does not prove future target-property
  semantics.
- Two negative controls show that neither naïve preflight alternative is
  production-ready. With a non-public override to the removed child, current
  resolution returns `forbiddenOverride`; slot-wins suppresses the unauthorized
  write and resolves, while conflict-reject masks it with `slotWriteConflict`.
  With two selected variants writing the same removed child path, current
  resolution returns `conflictingVariants`; slot-wins suppresses both and
  resolves, while conflict-reject again masks the existing typed error.
  Any candidate must preserve authorization and variant-conflict error
  precedence before deciding what to do with slot overlap.

## Inference and unknowns

Explicit slot-wins and preflight rejection each avoid silent loss in the tested
cases. The matrix does not decide which UX or persistence rule hamii should
adopt. It does not validate the candidate Document/Definition with
`DocumentValidator`, test malformed/duplicate IDs or overlapping API mappings,
resolve nested Definition dependencies, model multiple conflicting writes or
all error-precedence combinations, measure performance, or establish cache
invalidation. Production source, error enums, and persisted schema are
unchanged.
