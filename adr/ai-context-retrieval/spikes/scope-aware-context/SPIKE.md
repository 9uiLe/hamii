# Spike: Scope-aware AI Context Retrieval

## Related Decision

[Scope-aware AI Context Retrieval](../../ADR.md). This experiment tests semantic context sufficiency for representative authoring tasks. It does not decide the production CLI taxonomy or whether visual design tasks need pixels.

## Hypothesis

Scope-aware summary, bounded task detail, and on-demand resource queries can replace a full Document payload for three semantic tasks without weakening Scope or ClientPrecondition rules. Serialized bytes measure context volume, not AI total tokens.

## Questions

- Can a deterministic solver construct the correct entity IDs, AuthoringIntent, and mutation base solely from retrieved context?
- Do projected Component and Token candidates match existing Scope and availability evaluators, including unavailable resources?
- Does another coordinated mutation after retrieval make the old base fail with staleState?
- How do payload bytes, entity count, and query count scale from 1,000 to 10,000 Layers?
- What cross-file lookups does a raw Canonical shard strategy actually require?

## Prototype Scope

1. Build deterministic Current-format fixtures with exactly 1,000 and 10,000 Screen-tree Layers (count Screen roots; keep Component Definition trees constant and outside this count). Keep the selected Screen, target Layer subtree, Scope hierarchy, and available resources identical; put the extra 9,000 Layers in other Screens. Include at least three Pages, eight Screens, nested App → Commerce → Checkout and sibling Account ArchitectureScopes, available ancestor/local Components, sibling-owned and policy-denied Components, ancestor/local/sibling spacing Tokens, an Asset, ComponentInstance usage, AppSurface, and Target. Use fixed IDs or a fixed-seed derivation. Do not use UUID.random or EntityID.new in measurement fixture construction.
2. Precommit the task oracle below before writing prototype code. Record required facts, correct intent, forbidden choices, and expected semantic patch for each task. Use role-named stable IDs.
3. Compare FULL (one complete Document JSON response, equivalent to inspect --json), STAGED (summary → selected Screen/Layer detail → scoped resource list and optional selected detail), and RAW (actual Canonical shards and cross-file Scope/dependency reads). RAW is a control, not an API proposal. Count every response; no hidden file-oriented shortcuts.
4. Keep ContextEnvelope, ContextSummary, ScreenContext, LayerContext, ResourceSummary, ComponentDetail, and TokenDetail candidates test-only. Summary may include Document ID/revision, Page and Screen IDs/names, Screen Scope and surface/target hints, Scope summaries, and caller selection IDs. It omits complete Layer trees, Component Definitions, and Token values. Detail may contain bounded selected subtree/ancestry, navigation summary, and direct semantic references. Compare whole selected Screen with subtree plus ancestry if needed.
5. Use ScopeEvaluator, ComponentAvailability, ProjectService.availableComponents, availableTokens, and availableAssets as the oracle. IndexQuerySession.components may discover candidates, but Index rows alone are not assumed to be complete semantic detail. Do not invent a second availability rule.
6. Where possible, pass the solver-produced intent to ProjectService.mutate with the retrieved ClientPrecondition. Missing facts are incompleteness; an out-of-band Document read cannot repair the solver.

### Precommitted task oracle

| Task | Required returned facts | Correct operation | Forbidden choice / expected result |
| --- | --- | --- | --- |
| T1 Selection edit | Exact observation base, selected Screen and Layer IDs, text kind/current value, applicable Authoring constraint | Change only the selected Text Layer to a fixed replacement | No unrelated Screen/Component detail; patch changes only this Text |
| T2 Component insertion | Checkout consumer Scope, parent Layer ID, available Component summaries, selected Definition detail, availability and dependency context | Instantiate an App/Commerce-owned Component under the Checkout parent | Account-owned or denied Component is never usable |
| T3 Token assignment | Selected Layer semantic, Checkout Scope, available spacing Token summaries, selected value/alias detail, observation base | Assign an App/Commerce/Checkout-owned spacing Token | Account-owned spacing Token is never usable |
| N Negative Scope | Checkout Scope and an Account-owned resource that exists elsewhere | No mutation | No usable result or explicit unavailable result; zero Scope violations |
| S Stale base | T1 context at R0, followed by another coordinated mutation | Attempt T1 with R0 base | staleState; no overwrite |

The solver tests information sufficiency and mutation safety. It does not prove an LLM will always succeed.

The fixture fixes role IDs such as screen_checkout, layer_selected_text, layer_checkout_parent, component_price_badge, and token_spacing_checkout. T1's expected intent is setText(screen_checkout, layer_selected_text, "Updated order summary"); T2 is instantiate(screen_checkout, layer_checkout_parent, component_price_badge); T3 is setLayoutToken(screen_checkout, layer_checkout_parent, spacing, token_spacing_checkout). The prototype must not silently rename these roles to fit the measurements.

## Out of Scope

Production APIs/CLI taxonomy, GUI viewport capture, visual critique, provider/model/prompt selection, embeddings, network retrieval, AI autonomy, a general recent-change log, and full-gate optimization. A semantic task succeeding without pixels does not prove visual tasks need no visual context. Prototype code is not production code.

## Measurements

For every fixture size, task, strategy, and repeated deterministic run, serialize responses with JSONEncoder sortedKeys and record UTF-8 responseBytes, returned entity count, queryCount, cumulativeBytes, largest response, fullDocumentBytes, payloadRatio, oracleComplete, mutationVerified, scopeViolations, staleOverwrite, and missing facts. Count RAW shard and dependency reads. Record seed/version, source commit, environment, commands, failures, full-gate durationSeconds, and executed/skipped tests.

The matrix artifact must contain at least fixtureScale, task, strategy, queryCount, responseBytes[], cumulativeBytes, fullDocumentBytes, payloadRatio, oracleComplete, mutationVerified, scopeViolations, and staleOverwrite. AI total tokens: **unmeasured**. Do not convert bytes to tokens. Full-gate time is validation cost, not an AI-context benefit.

## Success Criteria

- T1–T3 are oracle-complete, yield unique correct IDs/intents, and real mutation produces the expected semantic patch.
- N exposes zero unavailable resources as usable. S rejects the old precondition with zero stale overwrites.
- STAGED never serializes a full Document or unrelated full Layer trees, uses at most **four query responses per scripted task**, and has no per-entity N+1 detail loop.
- For each representative task, STAGED cumulative bytes at 10k are at most **2.0×** its 1k bytes and at most **25%** of the 10k FULL payload. The 10k project summary is at most **64 KiB**. These are payload criteria, not product SLAs or AI token targets.
- Identical fixture input yields byte-identical baseline and retrieval output in at least three runs. Production Sources/ are unchanged.
- Full local gate and exact-SHA CI pass; zero tests or all skipped is not success.

## Failure Criteria

Missing required facts, wrong intent, Scope mismatch, stale overwrite, full Document hidden in STAGED, roughly document-proportional local-task growth, exceeded precommitted payload/query budgets, or nondeterminism fail the corresponding hypothesis. Omitting required semantics to meet a byte target is failure. A new embedding/provider/tokenizer dependency or production source change is a scope overrun.

## Result

Not run. Preserve failed, interrupted, and incomplete trials. Report payload bytes separately from unmeasured AI total tokens; do not extrapolate solver results to LLM success.

## Conclusion

Not decided. Compare FULL, STAGED, and RAW against these criteria before updating the ADR.

## Artifacts

Create artifacts/context-matrix.json and artifacts/strategy-comparison.md only when results exist. Do not commit generated builds or large fixture dumps.
