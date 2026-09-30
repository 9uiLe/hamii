# Canonical shard granularity

## Context

Canonical files support Git review/merge, stable resource identity and project restoration. A shard boundary affects local edit replacement payload, read locality and cross-file reference integrity. Current Format v2 stores each first-class entity separately: a Screen contains its complete Layer tree, and a ComponentDefinition contains its complete definition tree. Page organizes AppSurfaces that reference independently identified Screens; Page does not own Screen semantics.

## Decision to Make

Which Canonical shard boundary should hamii use, given the measured merge/read/save behavior and the validity, ownership and migration contracts?

## Constraints

- Preserve stable IDs, child order, references, Scope ownership and deterministic serialization.
- Canonical layout is separate from runtime object layout, query indexes and read optimization.
- Current authoring/currentness uses a fully validated coordinated Canonical observation. A read-only semantic slice cannot issue a Snapshot, ProjectObservation, ClientPrecondition or mutation base.
- An alternative layout needs product-relevant end-to-end benefit sufficient to justify format/migration/reference/freshness complexity. Payload bytes alone do not establish durable save or production read performance.
- Unmeasured cold-cache, many-shard scaling, AI total tokens/cost and broad production guarantees remain unmeasured.

## Options

| Candidate | Boundary | Evidence and cost |
|---|---|---|
| CURRENT | Format v2 entity-per-file; complete Screen and Component trees | Tested production load/observe/save and merge behavior; existing validation/recovery/Index/migration contracts; no extra cross-file subtree references or Canonical locator |
| MONOLITHIC | Test-only aggregate mapping of the complete Canonical inventory | No merge-frequency advantage in tested scenarios; local edits replace the aggregate; selected read requires the whole file |
| SUBTREE | Test-only externalization of each Screen's two child Stack trees | Smaller replacement and known-subtree read bytes; no tested merge-frequency advantage; no prototype partial latency advantage; extra references, reconstruction and locator/scan cost |
| Page ownership | Page owns Screens/trees | Inconsistent with Page's organization role and independent Screen identity; couples ownership to canvas organization |

A Page-based aggregate bucket without semantic ownership would still introduce grouping and local-edit amplification; no Page-specific performance benefit is established. SUBTREE is four child Stack shards in the fixture, not node-per-file.

## Current Hypothesis

**Recommended, not yet decided:** retain CURRENT entity-per-file sharding for Current Format v2. Under the tested workload and current validity/ownership contracts, the evidence does not justify replacing it with monolithic aggregation or subtree externalization. This is not a universal optimum or a claim that subtree reads cannot help another workload.

## Evidence Review

All completed phases of the [shard benchmark](spikes/shard-merge-benchmark/SPIKE.md) are reviewed below; raw artifacts remain unchanged.

### Observation reuse and file shape

[Observation-shape evidence](spikes/shard-merge-benchmark/artifacts/observation-shape-analysis.md) measured 10,002 Layers at 12/111/112 Canonical paths. Normal observe medians were 109.364/120.840/122.001 ms. Four-response workflows cost substantially more than the test-only single-observation workflow under these conditions. The separate context-session implementation addresses observation reuse; this evidence does not select a Canonical format.

### Merge semantics and normalized replacement payload

[Save/merge evidence](spikes/shard-merge-benchmark/artifacts/save-merge-analysis.md) includes 90 merges: independent text edits are clean for all candidates, while same-property and same-parent append conflict. The [common Foundation serializer control](spikes/shard-merge-benchmark/artifacts/open-save-scaling-analysis.md) repeats five scenarios across CURRENT-P and three normalized candidates (20 merges): classifications match, independent changes retain both deltas, and same-property/append conflict. No conflict-frequency difference was observed in these scenarios. Conflict markers/path/blob sizes are not semantic conflict counts.

With the common serializer, a 50k equal-length Text edit replaces 10,085,134 bytes in CURRENT-N, 21,774,372 in MONOLITHIC-N and 3,842,760 in SUBTREE-N. SUBTREE's replacement locality is supported; these payloads exclude journal/fsync/physical IO. Prototype encode/write is not production durable-save timing.

### Actual Current 50k path and candidate viability

Release warm-local CURRENT load/observe medians: 381.717/394.700 ms (n=10 each); actual ProjectService mutation save median: 2,134.925 ms (n=5 fresh copies). The tested path completed without correctness/OOM/runtime failure. These values are conditional measurements, not an SLA or a universal 50k guarantee.

All normalized candidates completed deterministic round-trip, actual Current parse/semantic validation, prototype open and encode/write at 1k/10k/50k. Candidate correctness alone did not eliminate any layout. Prototype timing has additional JSON-value reconstruction and different durability boundaries; it is not a production latency prediction.

### Read-only partiality and locator cost

[Partial-load evidence](spikes/shard-merge-benchmark/artifacts/partial-load-analysis.md): 270 partial runs, 90 paired full opens, 36 excluded recorded warm-ups, complete source binding and full-oracle equivalence. At 50k Task A, CURRENT/MONOLITHIC/SUBTREE read about 50%/100%/25% of their own candidate bytes. Median prototype latency was 460.099/501.532/535.184 ms (n=10). Fewer bytes did not establish a latency advantage. SUBTREE reconstruction includes Layer → Screen JSON → typed Screen work.

Task B loads a complete selected Screen, requiring both SUBTREE children. Task C requests the final Layer in the second subtree with no locator; both subtree files must be explored. Subtree canonicalization alone does not provide arbitrary Layer-ID location. A locator/index would be an additional mechanism with its own freshness contract; it is not implemented.

The tested closure covers nested Components, Token aliases/padding, system Asset, Interaction → Motion, Scope ancestors and availability deny Scope. It does not exhaust all API/variant/slot/custom-navigation combinations. Required missing/cyclic/malformed data is rejected. An unrelated invalid Screen leaves the selected slice identical while full Current validation rejects it. Thus local semantic equivalence is not global Canonical validity; sharding alone cannot replace the current full authoring validation contract.

### Limits and retained failures

Scaling fixtures have 13/1/17 paths; dependency-rich partial fixtures 18/1/22. Observation-shape includes 111/112 paths at 10k, but large file-count behavior is not exhaustively characterized. Many-subtree 50k, cold cache, complex reference-edit merge, peak RSS and AI total tokens/cost remain unmeasured. No p95/SLA/universal speed winner is inferred. These limitations do not supply a positive reason to introduce a new format; no additional benchmark is required solely to exclude unproven benefits.

Fixture preparation, compile and orchestration failures are retained with completed samples and explicit retry classifications. Partial-load failed attempts are not combined into accepted sample counts. Evidence distinguishes measured bytes, prototype operations and actual production APIs.

## Unknowns

No remaining evidence prerequisite for deciding the tested layout options. Broader workloads and performance limits above are not established. Read-only partial optimization and its authority boundary are separate concerns; no production partial reader is proposed here.

Reconsider subtree sharding only when a concrete product workload shows current entity shards are limiting and an alternative demonstrates end-to-end benefit while preserving Canonical validity, freshness, migration and authoring guarantees. No numeric SLA or automatic format change is implied.

## Required Evidence

- Completed [shard and merge benchmark](spikes/shard-merge-benchmark/SPIKE.md), including observation shape, serializer control, 50k open/save and read-only partiality.
- Ready-for-decision review: all phases synthesized, normalized serializer comparison, production/prototype timings separated, partial bytes/latency separated, locator/global validity/Page boundaries explicit, failures and unknowns retained.
- Markdown gate and exact-SHA Verify for this review, then a separate Decision commit.

## Decision Criteria

Choose a layout from measured product-relevant benefits and ownership/validity constraints. CURRENT's existing contracts are relevant responsibility boundaries, not a reason to avoid change merely because it exists. The observed alternatives' locality benefit has not established sufficient end-to-end advantage to justify additional Canonical reference/format complexity under this evidence.

Do not modify production format or implement a locator during review. Record the Decision independently, transfer current rules to permanent docs, validate existing implementation/coverage, and only then evaluate deletion under [ADR workflow](../../docs/adr-workflow.md).

## Status

Ready for Decision
