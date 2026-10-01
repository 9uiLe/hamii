# Migration Edge Composition

## Context

Current Canonical Format is v2. The isolated migration registry installs one v1→v2 edge; candidate preparation, review, publication, and recovery assume that source/target pair. A future Current v3 Screen format needs a reviewed path from both v1 and v2. This decision concerns migration orchestration across installed edges, regardless of what a particular edge transforms.

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

**Tentative, not a decision:** ordered adjacent edges may reuse the installed v1→v2 transform with less duplicated historical knowledge. The existing review and recovery records must still prove every edge and the exact final candidate.

## Unknowns

- How are missing or ambiguous routes rejected, and how is a route kept stable between preflight, review, publish, and recovery?
- How are v1→v2 resolution decisions bound when the final review target is v3?
- How are per-edge loss classifications and exact final bytes represented and verified?
- How do source changes, candidate tampering, stop/restart, and ref CAS affect a composed publication?
- Which existing review-record versions remain readable without introducing historical schemas into Current Core?

## Required Evidence

The [Ordered Edge Publication Spike](spikes/ordered-edge-publication/SPIKE.md) exercised the installed v1→v2 edge plus a synthetic 2→3 edge in a test-only route/review/Git publication/recovery harness. It covered v1→2→3 and v2→3, explicit v1 resolution, route ambiguity, source/intermediate/candidate/review tampering, exception stops on both sides of ref CAS, unchanged unrelated bytes, and an Index identity/generation double. The [Screen layout Spike](../screen-semantic-relation-persistence/spikes/canonical-layout-and-v3/SPIKE.md) had previously established only test-local sequential transform composability. Production still installs no v1→3 route and cannot read v3; this evidence supports a decision, not an implementation claim.

## Decision Criteria

Choose a route model only if it deterministically produces one final Current candidate, proves all edge classifications and resolutions in review, preserves unrelated bytes, rejects changed source or path, and recovers without exposing a partially migrated project. Compare implementation complexity and long-term cost of each option using the focused evidence.

The focused comparison below separates measured behavior from projected maintenance cost; no option is selected yet.

| Option | Evidence and correctness conditions | Implementation and long-term cost |
|---|---|---|
| Ordered adjacent edges | The test-only 1→2→3 and 2→3 paths produced one final candidate, bound receipts/resolutions, and recovered across tested CAS stops. Each installed edge must preserve its declared input/output identity and classification. | Reuses the installed 1→2 transform. Review and recovery must retain and replay every intermediate receipt; this protocol is additional implementation work, not a production result. |
| Direct source→Current edges | Not prototyped. Each supported historical source would need its own reviewed route and proof that shared historical decisions and loss accounting match. | A new Current format would require source-specific composite transforms. Duplication and drift are plausible costs inferred from the current installed 1→2 edge, not measured. |
| Constrained installed-edge graph | The test-only resolver rejected missing, ambiguous, backward, self, and duplicate edges; it used a deliberately narrow increasing-version rule. Graph-level publication semantics were not separately prototyped. | Allows reuse of installed edges, but catalog validation and stable path selection/review binding add policy surface. Cost relative to explicit adjacent routes remains unmeasured. |

## Status

Ready for Decision
