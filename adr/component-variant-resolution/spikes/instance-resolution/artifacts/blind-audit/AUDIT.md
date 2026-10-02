# Independent audit of instance-resolution probes

The [checklist](CHECKLIST.md) was fixed before the precedence and scale probes
were inspected. This audit uses their probe source and `result.json` files, plus
the production model and resolver. It does not treat prototype output as a
production decision or cache implementation.

## Evidence reviewed

- [Precedence probe](../precedence-correctness/probe.swift) and [raw result](../precedence-correctness/result.json): one execution, 16/16 listed cases
  passed. The test compares selected fields or an error code; most cases do
  not compare an entire resolved tree.
- [Scale probe](../scale-locality/Probe.swift) and [raw result](../scale-locality/result.json): one 1,000-instance fixture, one real Current Canonical save,
  40 measured direct-resolver trials per timing case after five warmups.

## Checklist disposition

1. **Silent overwrite: confirmed gap.** Two selected axes that write the same
   path throw `conflictingVariants`, including when both values are equal.
   Disjoint axes produce the same full tree for the two tested insertion and
   Variant-definition orders. In contrast, a property value silently replaces
   a Variant value, and a public path override silently replaces the property
   value. A slot replacement after a property or Variant write deletes that
   changed descendant yet returns `resolved`; the later public override on the
   removed path throws `unknownPath`. Thus sorted application order describes
   the current behavior, but does not settle the intended precedence or
   whether discarded writes require a diagnostic.
2. **Validation boundary: partial.** Direct Resolver errors were measured for
   unknown axis/value, property, slot, path, and forbidden override. The
   precedence probe did not call `DocumentValidator` or Canonical storage for
   these invalid cases. It did not test duplicate axis/value declarations,
   invalid slot target kind, or every ordering permutation. Its fixture embeds
   a reference to `component_nested` without supplying that Definition to a
   Document, so it is not a valid whole-Document nested example.
3. **Nested Definition: unresolved.** The direct resolved output retains a
   `componentInstance` node pointing to `component_nested`. This confirms the
   current Resolver does not recursively expand it. No A→B valid nested tree,
   A→B→A cycle, nested slot resolution, or corresponding validator rejection
   was exercised. Component availability recursion is a separate code path.
4. **Storage and locality: bounded evidence.** The scale fixture with one
   seven-Layer Definition and 1,000 Instances passed `DocumentValidator` and
   `CanonicalRepository.commit`. Its screen shard is 652,141 bytes, Component
   shard 2,895 bytes, and root JSON total 655,792 bytes (including manifest,
   Scope, and Agent profiles). The probe reads real persisted bytes for these
   numbers. It then resolves **all 1,000** Instances after each edit and
   compares output trees: changing Instance 500 changes only output 500;
   changing an unoverridden Definition detail changes all 1,000 outputs.
   These are logical affected-output counts, not observed incremental
   invalidation or recomputation counts. No production resolver cache exists.
5. **Storage comparison and performance: qualified.** The test-only 2,657,591
   byte materialized Screen is encoded directly by generic `JSONEncoder` from
   resolved trees, while the 652,141 byte sparse Screen is a Current Canonical
   shard encoded through `CanonicalDocumentV3Codec`. The approximate quotient
   is 4.075, but the encodings and persisted-data boundaries differ; it is
   **not** a measured 4.075× Canonical storage saving. Comparing the test-only
   Screen with the 655,792 byte whole root JSON total would additionally mix
   Screen-only numerator with multi-shard denominator. The 1,984,120 byte
   materialized-subtree sum is a third, different boundary. For this small
   fixed fixture, raw direct-resolution times (ms; 40 trials, nearest-rank
   p95) are one Instance p50 0.009875, p95 0.010500, max 0.020292; all 1,000
   p50 8.703459, p95 8.734084, max 8.768791. They omit discovery,
   invalidation, Canonical observation, validation, serialization, and cache
   work. A one-versus-1,000 timing ratio is not an incremental-update speedup.
6. **Architecture authority: partial.** The real scale Document's validation
   and save establish that the simple reference/delta model persists for this
   fixture. The direct precedence probe does not establish production
   rejection or Canonical non-persistence for its conflicts. Owner Scope on the
   Definition and nested availability/cycle rules remain separate from the
   measured Resolver behavior. Neither probe changes production code.

## Claims the decision must not promote from these probes

- No tested result proves a correct general cross-stage precedence; slot
  replacement currently loses earlier property/Variant writes without notice.
- No tested result proves nested Definition expansion, nested cycle handling,
  a production cache, targeted invalidation, or local recomputation.
- The synthetic materialized JSON comparison is not an exact Current Canonical
  size comparison, and the direct Resolver timing is not end-to-end UI editing
  latency or a Product SLA.
- A Resolver throw alone does not prove that the corresponding invalid
  candidate was rejected by `DocumentValidator` and persisted storage.

## Remaining focused inputs for a decision

Define or reject each cross-stage collision explicitly, especially writes
discarded by slot replacement. Exercise invalid combinations through
`DocumentValidator` and Canonical save. Use valid nested Definitions to test
expansion and cycles. If cache/locality is part of the selected option,
measure changed **and recomputed** sets with an actual prototype cache;
otherwise describe current full recomputation honestly. Compare storage with
the same encoder and entity boundary before assigning a size reduction ratio.
