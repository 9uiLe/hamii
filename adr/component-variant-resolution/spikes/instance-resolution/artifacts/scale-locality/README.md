# Current ComponentResolver scale and locality probe

Evidence-only probe of the production `ComponentResolver.resolve` and Current
Canonical storage. `Probe.swift` creates one Definition with seven Layers
(one root Stack and six Text children), one `size=large` Variant, one public
`title` property, and 1000 sparse ComponentInstances, each selecting that
Variant and setting its own title. `result.json` contains every trial and the
full affected-output indices. No resolver cache or invalidation path exists in
this measurement.

## Reproduce

Measured at source commit `e5bcd56c9e953a6e8d79661b35396d1cddff15c3`,
macOS 27.0 arm64, Apple M1 Pro, 10 logical CPUs, 16 GiB RAM, Apple Swift 6.4.
The direct probe was compiled in debug mode against SwiftPM's debug objects.
Other machine load was not fixed. This is local evidence, not an SLA.

```sh
git diff --quiet e5bcd56c9e953a6e8d79661b35396d1cddff15c3 -- Package.swift Package.resolved Sources
test -z "$(git ls-files --others --exclude-standard -- Package.swift Package.resolved Sources)"
swift build --product hamii
swiftc -I .build/debug \
  adr/component-variant-resolution/spikes/instance-resolution/artifacts/scale-locality/Probe.swift \
  .build/debug/HamiiFormat.o .build/debug/HamiiApplication.o .build/debug/HamiiCore.o \
  -o /tmp/hamii-component-scale-probe
/tmp/hamii-component-scale-probe > \
  adr/component-variant-resolution/spikes/instance-resolution/artifacts/scale-locality/result.json
```

The probe makes a temporary project outside the checkout, commits the sparse
Document through `CanonicalRepository`, reads its real Current JSON shards,
and removes the project. `DocumentValidator.validate` returned no diagnostics.
The first local attempt ended before timing with exit 133 because the probe's
relative-path calculation did not normalize macOS `/var` versus `/private/var`;
the source was corrected before the reported 40-trial run. That failed attempt
has no valid measurements and is not included in the raw arrays.

## Measured resolver time

`DispatchTime.now().uptimeNanoseconds` surrounds only the direct resolver
call(s), excluding fixture construction, Canonical save, and JSON encoding.
Five warmups per case, then 40 interleaved trials. p95 uses nearest rank;
`result.json` carries all 40 values for each case.

| Case | n | p50 ms | p95 ms | max ms |
| --- | ---: | ---: | ---: | ---: |
| One selected instance | 40 | 0.009875 | 0.010500 | 0.020292 |
| All 1000 instances, sequential resolve | 40 | 8.703459 | 8.734084 | 8.768791 |

The one-instance result does not establish cache-hit latency. The full result
is a serial loop over 1000 calls, not a real editor frame or mutation
end-to-end measurement.

## Logical affected outputs

The probe resolves all 1000 instances before and after each change and
compares the resulting `Layer` trees. Changing only instance 500's `title`
property changes exactly output index 500 (1/1000). Changing the Definition's
shared Detail text changes output indices 0 through 999 (1000/1000). These
are output-difference sets after full recomputation, not observed production
cache invalidations or invalidation latencies. A dependency-aware cache could
use them as correctness targets, but its key, publication, and invalidation
strategy remain undecided.

## Storage bytes

All Current Canonical JSON files were measured from the temporary project,
including `hamii-agent-profiles.json`. The sparse screen shard contains the
1000 instance references and overrides. The hypothetical materialized tree
was created only in memory by resolving each instance and namespacing its
Layer IDs to avoid duplicate IDs; it is not a production persisted format.
Both encodings use sorted-key, pretty-printed JSON, no escaped slashes, plus
one newline. The Current sparse shard is persisted by
`CanonicalDocumentV3Codec`; the test-only materialized Screen is encoded
directly by `JSONEncoder` with a different entity shape and is not a Current
Canonical shard.

| Data | Bytes |
| --- | ---: |
| Sparse Current Canonical project, all JSON shards | 655,792 |
| Sparse `screens/screen_scale.json` shard | 652,141 |
| Sparse `components/component_card.json` shard | 2,895 |
| Test-only 1000 materialized resolved subtree JSON objects | 1,984,120 |
| Test-only materialized screen JSON shard | 2,657,591 |

For this fixture the quotient of materialized Screen JSON bytes over sparse
Screen shard bytes is about 4.08. Because the schema and encoding boundary
differ, this is only an illustration of these two artifacts. It is not a
measured Canonical storage saving, a claim about all components, or a
validated alternative Canonical schema.

## Unknown / not implemented

- Resolver caching, cache hit rate, actual invalidation cost, and end-to-end
  editor latency were not measured; no cache was implemented.
- The Definition has one Variant axis with no conflicting path. Multi-axis
  precedence, conflict diagnosis, and nested Definition semantics are separate
  cases within the parent Spike.
- The test-only materialized representation is not a Current hamii write
  path. It was never published to a Canonical Repository.
