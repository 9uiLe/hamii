# Context session CLI

`hamii --project PATH --json query context session [--screen SCREEN_ID [--layer LAYER_ID]]` starts one read session in one OS process. The first stdout line is the same `Output.context` summary as the one-shot summary command. Each stdin line is a JSON object; responses are one JSON line, written immediately. Read a response before sending the next request.

| Operation | Required fields | Optional fields |
| --- | --- | --- |
| `layer` | `op`, `screenID`, `layerID` | none |
| `resources` | `op`, `consumerScopeID`, `kind` | `matching`, `limit` |
| `component` | `op`, `consumerScopeID`, `componentID` | none |
| `token` | `op`, `consumerScopeID`, `tokenID` | none |
| `close` | `op` | none |

`op` is the operation name. IDs must be nonempty strings. `kind` is `component`, `token` or `asset`. `matching` is a string. `limit` is an integer in 1…100 (default 32). Unknown operations/fields, incorrect types and malformed JSON return `usage` with `terminal: false`. Lines over 64 KiB are discarded through the newline and return the same nonterminal error. Missing/unavailable entities return `notFound` with `terminal: false`. No request accepts a state token or mutation.

Example stdin:

```json
{"op":"resources","consumerScopeID":"scope_app","kind":"component","matching":"Button","limit":8}
{"op":"component","consumerScopeID":"scope_app","componentID":"component_button"}
{"op":"close"}
```

All successful context responses identify the initial observation S0. Each follow-up verifies the exact S0 precondition using the production verifier before projection. A mismatch, pending transition or storage failure returns no context payload, sets `terminal: true` and ends the process using the existing error category/exit status (`conflict`: 3; `transitionPending`/`storage`: 7). Start a new session and obtain a new summary. The process never automatically refreshes S0.

EOF exits 0 without an additional response. `close` returns `{"ok":true,"message":"Context session closed"}` and exits 0. The session holds no worktree lock while waiting for input and does not survive restart. There is no daemon, socket, disk/global registry or session ID. One-shot context commands remain available.

Mutations use existing one-shot commands with `--state TOKEN`, using the summary's `context.observation.statePrecondition.rawValue`. `ProjectService` revalidates the token at mutation time; the read session does not authorize writes. Never combine responses from different observations. Use `hamii skills get context --json` for installed-version guidance.

Regression checks: `python3 scripts/test-context-session.py --binary .build/debug/hamii`. The full XCTest gate runs these real-process checks through `ContextSessionCLITests`; Application tests additionally check exact observation/verification counts and failure invalidation.

[Release comparison](context-session-performance.md) records paired CURRENT/SESSION retrieval time, equivalent payloads and unmeasured token/cost boundaries.
