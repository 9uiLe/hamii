# Scope-aware context strategy comparison

## Conditions

- Source baseline: plan commit 36c9889b0aec5d3ea569a46f4efc55e96abc478e. Prototype and measurement are test-only; no production Sources/ changes.
- Environment: macOS 27.0 (26A428), arm64, Apple Swift 6.4. Local focused command: HAMII_CONTEXT_SPIKE_RESULT=adr/ai-context-retrieval/spikes/scope-aware-context/artifacts/context-matrix.json swift test --filter AIContextRetrievalSpikeTests.testContextSufficiencyAndPayloadScaling.
- Deterministic fixtures: 1,000 and 10,000 Screen-tree Layers, eight Screens, three Pages, App/Commerce/Checkout and sibling Account Scopes, five Components, four spacing Tokens, one Asset, ComponentInstance, eight AppSurfaces, one Target. The selected Checkout Screen has the same 64 Layers at both scales; extra Layers are in other Screens. Measurement IDs and source values are fixed. The whole matrix was rebuilt three times and sorted-key serialized output was byte-identical.
- FULL is a sorted-key JSON envelope with the whole Document. STAGED is a test-only semantic summary, selected Layer detail, scoped resource list, and optional selected detail. RAW uses a small observation header and individual Current-format Canonical shards. The raw shard set was accepted by the actual Current reader. All strategies include the same observation base.
- A deterministic solver consumes decoded responses, constructs the specified intents, and calls the actual ProjectService mutation path. Existing ScopeEvaluator, ComponentAvailability, and ProjectService resource lists are the availability oracle. This is a context sufficiency test, not an LLM trial.

## Payload and query results

Each cell is cumulative UTF-8 bytes / query responses. The full row data, per-response sizes, entity counts, and correctness fields are in [context-matrix.json](context-matrix.json).

| Scale | Task | FULL | STAGED | RAW |
| --- | --- | ---: | ---: | ---: |
| 1k | T1 Text selection | 158,236 / 1 | 2,138 / 2 | 22,698 / 7 |
| 1k | T2 Component insertion | 158,236 / 1 | 2,968 / 4 | 27,027 / 12 |
| 1k | T3 Token assignment | 158,236 / 1 | 2,977 / 4 | 23,670 / 11 |
| 1k | N unavailable Component | 158,236 / 1 | 2,673 / 3 | 27,027 / 12 |
| 1k | S stale selection | 158,236 / 1 | 2,138 / 2 | 22,698 / 7 |
| 10k | T1 Text selection | 1,535,023 / 1 | 2,138 / 2 | 22,698 / 7 |
| 10k | T2 Component insertion | 1,535,023 / 1 | 2,968 / 4 | 27,027 / 12 |
| 10k | T3 Token assignment | 1,535,023 / 1 | 2,977 / 4 | 23,670 / 11 |
| 10k | N unavailable Component | 1,535,023 / 1 | 2,673 / 3 | 27,027 / 12 |
| 10k | S stale selection | 1,535,023 / 1 | 2,138 / 2 | 22,698 / 7 |

At 10k, STAGED uses 0.139% (T1/S), 0.193% (T2), 0.194% (T3), and 0.174% (N) of FULL response bytes. STAGED's local-task bytes and 1,820-byte project summary are unchanged between fixture sizes; FULL grows about 9.7×. Every representative STAGED task meets the precommitted 2.0× scaling, 25% FULL, four-response, and 64 KiB summary bounds. RAW is also size-stable for these local tasks, but it returns roughly 8–12× STAGED bytes and requires 7–12 file-oriented responses.

## Correctness

All 30 scale × task × strategy rows report oracleComplete=true, mutationVerified=true, scopeViolations=0, staleOverwrite=false. T2 excludes Account-owned and Checkout-denied Components. T3 excludes the Account Token and resolves the Checkout alias to the Commerce spacing literal. A separate test used two real CanonicalRepository instances with ProjectService: after one coordinated mutation, the other's R0 ClientPrecondition failed with staleState and the newer Text remained intact. Current-format shard loading, component availability, Token availability, and Asset availability matched the production reader/services.

The first focused attempt failed a whole-Document equality check because Current shard loading reconstructs arrays in path order; entity-ID-sorted shard comparisons passed. A second attempt exposed a Canonical save conflict because the test's compact JSON bytes did not match the production pretty-printed Canonical writer. The raw fixture writer was corrected to the Current format's sorted/pretty/newline representation. The subsequent focused run passed 3 tests with no failures. These failed attempts are retained here; they are not counted as successful trials.

## Limits

- AI total tokens, cached tokens, reasoning tokens, provider cost, and LLM task success: **unmeasured**. No byte-to-token conversion is made.
- The added 9,000 Layers are outside the selected Screen. Growth inside the selected Screen, more Scopes/Components/Tokens, visual tasks, and retrieval compute/query latency remain unmeasured.
- The test-only projector can inspect an in-memory Document to build STAGED responses. Its small output does not prove a production query can avoid full Canonical parsing or implement the same path efficiently.
- The local matrix reports serialized payload, not full development-cycle time or a full-gate speed improvement. The full gate and exact-SHA CI are separate validation results.

## Validation

The local full gate passed 14/14 checks in 861.036 seconds: 276 Swift tests executed, 58 skipped, and zero failures. The detailed local, untracked log is .build/verify-logs/20260929-084341-677618-79244-full.log. The focused prototype run passed 3 tests; the artifact-producing run passed 1 selected test. The exact pushed-SHA CI result is pending at Evidence commit time.
