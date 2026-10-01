# Migration Edge Composition

## Context

Current Canonical Format is v3. The isolated migration registry installs v1→2 and 2→3 adjacent edges. Public candidate preparation, review, publication, and recovery target final v3 from either historical v1 or v2. This decision concerns migration orchestration across installed edges, regardless of what a particular edge transforms.

## Decision to Make

How should the Migration subsystem compose multiple reviewed format edges into one deterministic, source-bound, reviewable, publishable Current-format candidate and recover that publication?

## Constraints

- Current Core reads only Current Format. Historical models remain inside the Migration boundary.
- A candidate's final bytes, every edge and its loss classification, required human resolutions, review, and source state must be bound together. No edge may infer missing semantic relations.
- Preserve unrelated Canonical shards and blobs unless an explicit edge declares and validates a change.
- Publication remains candidate-based with source comparison and fail-closed recovery; a partially applied path is not a usable Current project.
- Document format version and Repository Profile format version remain independent.

## Options

1. Explicit ordered adjacent edges, folded into one final candidate and review record.
2. Direct source→Current composite edges for each supported historical version.
3. Constrained installed-edge graph with deterministic path selection and ambiguity rejection.

## Current Hypothesis

Resolved by the decision below. The ordered-edge Spike supports reusing the installed v1→v2 transform while retaining one final candidate-based publication.

## Decision

**Adopt Option 1: explicit ordered adjacent edges.** From historical source format `S` to Current format `C`, install exactly one edge for every `S→S+1, S+1→S+2, …, C-1→C` step. Missing or duplicate adjacent edges, nonadjacent/backward/self edges, and catalogs offering more than one route fail closed. No shortest-path, priority, direct-edge preference, or general graph traversal is part of this contract. A future requirement that cannot be expressed as an adjacent chain requires a separate decision.

Each edge owns only its declared input/output formats. Human resolution, loss audit, and classification belong to that edge; a resolution for an edge absent from the selected route is rejected. The v1→v2 edge keeps its existing source-bound resolution meaning. An edge must not reinterpret decisions made by an earlier edge or infer missing semantic relations. Historical models remain in the Migration subsystem, outside Current Core.

The final review binds the original source ref, commit OID, tree OID, Canonical identity and format; final Current target format; exact ordered edge IDs and receipts; each receipt's input/output identity and classification; edge-local resolutions and losses; final candidate commit/tree/Canonical identity; changed paths; and immutable retention ref. Adjacent receipts must satisfy `previous.outputIdentity == next.inputIdentity`. Publisher and recovery independently rerun the entire installed route from the original source commit, compare receipts/audit/final bytes with the reviewed immutable candidate, and reject a changed source or path. Intermediate formats are never a publication state.

Git source-ref compare-and-swap remains the sole Canonical publication commit point. Before CAS, recovery retains the original historical source; after CAS, it rolls forward to the validated final Current candidate. A ref matching neither old nor candidate remains gated. Current-format queries are refused until final Current validation and a matching derived Index are complete. Index failure does not roll back Canonical publication.

Existing review-record formats 1 and 2 retain their single-edge interpretation. Composed routes require a new review-record format; old records are never silently reinterpreted as multi-edge reviews. Its numeric version and Swift field layout are implementation details. This decision does not establish SIGKILL or power-loss durability; those require production validation and the existing durability boundary.

## Unknowns

The route decision and Current v3 cutover implementation are complete. The remaining gate in this ADR is integrated verification of real two-edge publication/recovery, Human resolution, process-stop behavior, historical pending recovery, and exact pushed SHA Verify. This ADR stays `Implementation Required` until that validation is complete and a separate closure commit is justified. Power-loss durability belongs to its separate ADR.

## Required Evidence

The [Ordered Edge Publication Spike](spikes/ordered-edge-publication/SPIKE.md) exercised the installed v1→v2 edge plus a synthetic 2→3 edge in a test-only route/review/Git publication/recovery harness. It covered v1→2→3 and v2→3, explicit v1 resolution, route ambiguity, source/intermediate/candidate/review tampering, exception stops on both sides of ref CAS, unchanged unrelated bytes, and an Index identity/generation double. Independent review added regression cases for historical-source/Current-query separation, resolution outside the route, and pending-record misclassification; the corrected focused run passed 8 tests. The [Screen layout Spike](../screen-semantic-relation-persistence/spikes/canonical-layout-and-v3/SPIKE.md) established test-local sequential transform composability. That Spike evidence supports the route decision; current production replay of the real 2→3 edge is recorded below. At the time of that Spike, public candidate preparation and Current reading still targeted v2; the cutover is now implemented.

Production tests with the real v1→v2 edge now exercise record 3 creation and strict store decoding, edge-local replay, pending record 2, source-commit replay before HEAD classification, 13 exception-stop points, tampered pending/review/retention evidence, pre-CAS historical abort, post-CAS roll-forward, dirty-worktree rematerialization, derived Index failure/rebuild, repeated recovery, and Human resolution audit. A five-stage separate-process SIGKILL test also confirms reader lock contention until writer death, pending Query rejection, and old/candidate recovery for the composed record. These are one-edge composed-protocol results. They do not establish an installed multi-edge route or power-loss durability.

The Screen-owned semantic v3 codec, Core validator, and journal recovery test provide a strict Current target-file-set boundary for the 2→3 edge.
The Foundation-only FormatV2 edge now accepts exact 2/2 markers, rejects preexisting Screen semantics, adds explicit empty declarations without inference, and leaves unrelated Canonical bytes unchanged. The Runtime replays real 2→3 and 1→2→3 routes, binds receipt identities, and validates final v3 bytes through the package-level strict codec and `DocumentValidator`. Those edge and replay results remain independent evidence for the integrated Current v3 preparation and publication path.

The Current v3 focused integration tests prepared real v1→2→3 and v2→3 record-3 candidates from original source commits, verified receipts and an edge-local v1 resolution audit, and published only final v3 CanonicalSnapshot/Index state (preparation 2/2; publication 3/3; CLI end-to-end 1/1). Four historical pending-recovery tests verified raw v2 recovery for record-1 and record-2 target-v2 stops without publishing v2 as a Current Index. These are process/test-environment results; full gate, exact-SHA CI, and power-loss durability are separate validation boundaries.

## Decision Criteria

Choose a route model only if it deterministically produces one final Current candidate, proves all edge classifications and resolutions in review, preserves unrelated bytes, rejects changed source or path, and recovers without exposing a partially migrated project. Compare implementation complexity and long-term cost of each option using the focused evidence.

The focused comparison below separates measured behavior from projected maintenance cost. Option 1 was selected because it reused the installed 1→2 edge and met the tested route, review, and publication invariants without requiring a duplicate direct transform or general graph policy.

| Option | Evidence and correctness conditions | Implementation and long-term cost |
|---|---|---|
| Ordered adjacent edges | The test-only 1→2→3 and 2→3 paths produced one final candidate, bound receipts/resolutions, and recovered across tested CAS stops. Each installed edge must preserve its declared input/output identity and classification. | Reuses the installed 1→2 transform. Review and recovery must retain and replay every intermediate receipt; this protocol is additional implementation work, not a production result. |
| Direct source→Current edges | Not prototyped. Each supported historical source would need its own reviewed route and proof that shared historical decisions and loss accounting match. | A new Current format would require source-specific composite transforms. Duplication and drift are plausible costs inferred from the current installed 1→2 edge, not measured. |
| Constrained installed-edge graph | The test-only resolver rejected missing, ambiguous, backward, self, and duplicate edges; it used a deliberately narrow increasing-version rule. Graph-level publication semantics were not separately prototyped. | Allows reuse of installed edges, but catalog validation and stable path selection/review binding add policy surface. Cost relative to explicit adjacent routes remains unmeasured. |

## Implementation Gates

- Production `HamiiMigrations` must represent ordered adjacent routes and per-edge receipts. The v1→2 transform and edge-local resolution behavior must remain stable when followed by 2→3.
- Candidate preparation, review, publication, and recovery must share full-route replay from the exact original source. A new composed review-record format must be strict; existing formats 1 and 2 must retain their single-edge meanings.
- The installed 2→3 edge must use a strict Current-v3 validator and an Index built from the exact final CanonicalSnapshot. Pre-CAS historical abort must not permit Current queries; post-CAS recovery must not publish intermediate v2 or mismatched Index state.
- Production stop/restart and tamper tests must cover the committed publication protocol. SIGKILL evidence is distinct from the separate [Power-loss ADR](../canonical-power-loss-durability/ADR.md).

## Status

Implementation Required
