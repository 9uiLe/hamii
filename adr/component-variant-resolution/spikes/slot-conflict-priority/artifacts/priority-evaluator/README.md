# Test-only slot conflict priority evaluator

From the repository root:

```sh
HAMII_SOURCE_COMMIT=$(git rev-parse HEAD) sh adr/component-variant-resolution/spikes/slot-conflict-priority/artifacts/priority-evaluator/run.sh > /tmp/hamii-slot-priority-result.json
```

`run.sh` builds an isolated temporary Swift package against the repository's
`HamiiCore`, runs `probe.swift`, and removes the package. It exits nonzero on a
matrix mismatch. The committed `result.json` records 18/18 passing candidate
expectations on source commit `c43ea3179559d55049db4e98db4cf013e81b0588`,
Swift 6.4, arm64 macOS 27. One run is not a latency benchmark.

## Candidate and controls

This evaluator is **test-only**. It checks existing selection/API validity
(unknown variant/property/slot, invalid property path/kind, forbidden override),
then duplicate paths among selected variants, then selected variant and
`propertyValues` writes to old descendants of selected slot targets. The new
diagnostic has `error: slotWriteConflict`, the path, and the **full sorted set**
of selected slot names that delete that path. `allowedOverrides` are excluded
from the new conflict and reach the current resolver. When no new conflict is
found, the current `ComponentResolver.resolve` runs unchanged. No production
error enum or schema was modified.

The fixed Definition has an outer slot containing an inner slot containing old
text, plus an outside text sibling. The strict-descendant relation excludes
the slot target itself. Replacing inner reports `['inner']`, replacing outer
reports `['outer']`, and replacing both reports `['inner','outer']` for the same
old text path. Empty and nonempty replacements both remove old children. An
unselected variant, an outside write, and an instance without slot replacement
remain on the current resolver path. Changing dictionary insertion order does
not change the candidate result.

The single-invalidity controls preserve the tested existing typed errors before
the new conflict: `unknownVariant`, `unknownProperty`, `unknownSlot`,
`forbiddenOverride`, invalid property kind/`unknownPath`, and
`conflictingVariants` for two selected variants writing the same path. A public
`allowedOverrides` write to a removed old path still returns the current
`unknownPath`; the new conflict does not cover it.

## Material priority limits

The candidate does **not** preserve every current error priority. With both
nested slots selected, lexicographic `inner` then `outer` processing in the
current resolver succeeds and drops the old child. Renaming them `aOuter` and
`zInner` makes the current resolver process outer first and then return
`unknownSlot:zInner`, because the inner target has been removed. The candidate
preflight returns `slotWriteConflict` with sorted names `['aOuter','zInner']`
before reaching that dynamic `unknownSlot`. This is an explicit masking case,
not evidence that the new diagnostic should win.

Likewise, a deliberately mixed-invalidity fixture with both duplicate selected
variant writes and a forbidden override returns `conflictingVariants` from the
current resolver, but the specified validity-first candidate returns
`forbiddenOverride`. The ordering of simultaneous failures is unresolved.
Claims here are limited to the fixed cases and to preservation of individual
existing error categories, not full error-precedence equivalence.

The prototype checks paths and slot targets against the Definition tree. It
does not model all runtime tree changes caused by nested slot replacement,
duplicate IDs, malformed or overlapping APIs, persisted Document validation,
cross-Definition resolution, cache invalidation, or performance. The ADR must
decide error priority and nested-slot semantics before any production adoption.
