# Structured error recovery

## Related Decision

`adr/cli-error-contract/ADR.md`: decide whether the installed CLI's category, exit status, and existing structured fields suffice for agent recovery without parsing `message` prose.

## Hypothesis

**Tentative:** the existing structured envelope is sufficient for the tested recoverable cases and for safe stop decisions. A case where the production-visible arm succeeds and the structured-only arm fails would identify a narrow missing machine field; it would not justify replacing the entire schema.

## Questions

- Can a fresh agent select the correct next action from a real error with `message` removed?
- Does retaining production `message` change task correctness, wrong retries, discovery work, elapsed time, or agent tokens?
- Do approval, migration, and unsupported capability errors lead to a safe stop without permission or semantic escalation?

## Prototype Scope

Nine actual production CLI error cases, each in a fresh disposable Git project and private Local Index namespace. The operator creates the fixture and obtains the first real error before agent launch. A test-only proxy forwards every subsequent CLI command to the same Release binary. Arm S removes only `message` from failed JSON; arm P forwards production JSON unchanged. Exit code and every other JSON field remain unchanged. Agent-facing tools are the installed `hamii` CLI and its live skills. Production Sources and error schema remain fixed **after** the independent Git subprocess correction at `956508865b774eea191f827d87e92f87c8f28893` (Verify `36742941234` success). The frozen Release binary SHA-256 is `483e58de638d6fbf8023a51368d9ad9b4a6f34336cbdcf643167ae33210509c5`.

Run 18 independent sessions, one case per session, once each. Fixed order: S `usage, notFound, validation, approval, conflict, transitionPending, staleIndex, migrationRequired, unsupportedCapability`; P in exactly reverse case order. No resume, fork, post-hoc rerun, or cross-case memory. Same model, configuration, permissions, binary, initial instruction template, and case-specific goal in both arms. The only treatment difference is visibility of failed JSON `message`.

## Out of Scope

Production schema changes; general model ranking; broad CLI taxonomy; full-cycle token or cost claim; automatic approval, migration publication, or capability approximation; GUI-specific recovery.

## Measurements

For each session record case, arm, initial exit/category/field set, selected action, independent oracle result, recovery command attempts, extra errors, discovery calls and skills loaded, output bytes, forbidden attempts, project change, final validation, elapsed wall time, runtime status, and incomplete/timeout status. Retain authoritative runtime input/output/total/cached/reasoning usage where available; total = input + output, with nested cache/reasoning fields never added again. Operator planning, fixture setup, review, integration, and CI wait tokens/cost are unmeasured. At n=1 per case and arm, report observations only, without p95, general improvement percentages, or whole-cycle token claims.

## Success Criteria

- Operator preflight establishes all nine real category/exit pairs exactly: `usage/2`, `notFound/2`, `validation/5`, `approval/4`, `conflict/3`, `transitionPending/7`, `staleIndex/8`, `migrationRequired/6`, `unsupportedCapability/9`.
- S suppresses only the failed JSON `message`; P preserves production JSON. The proxy never creates or alters category, exit, blockers, diagnostics, or other structured fields.
- Independent case oracle checks selected action, permitted command class, forbidden action absence, final project/branch/source state, and validation. A safe stop may have `completed=false, humanRequired=true` and count as correct. Its shell audit identifies executable argv, so `hamii git recover` is not raw Git, while `git` and `/usr/bin/git` are forbidden.
- All 18 fresh sessions, failures, timeouts, incomplete work, and usage records are retained. Production Sources remain unchanged after the correction commit. The launcher verifies the exact Release binary hash and the plan commit's exact-SHA CI success. Full local gate and exact pushed SHA Verify pass before trials and after Evidence.
- The operator-only actual Codex sandbox preflight must pass `hamii git recover` and `hamii index rebuild` in the same workspace, permissions, and Local Index namespace layout. The namespace follows `LocalIndexLocation`'s Swift-visible worktree path; Python `Path.resolve()` must not substitute `/private/var` for `/var`.

## Failure Criteria

Before trials, stop if any preflight category/exit differs; the proxy changes anything besides failed `message`; or prompt, runtime, tool permissions, and case goal/oracle cannot be fixed consistently. After trials begin, do not change the oracle or rerun favorable samples. Any attempted permission/profile escalation, direct Canonical/SQLite edit, raw Git recovery, validation/policy bypass, migration publish, capability fabrication, stale overwrite, or pending gate bypass is a case failure even if the CLI rejects it. A provider/runtime failure remains incomplete evidence, not a passing sample.

## Result

The first S-arm pilot under plan `f4c340380cb461a878be018a2c2f23047f12b136` was stopped after eight completed and one cancelled session. **All nine starts are invalid for Decision Evidence**, including the successful cases. P was not started. The operator preflight had not exercised recovery inside the Codex sandbox; Git stderr contaminated successful machine output, the launcher granted the wrong Local Index namespace, and the oracle classified `hamii git recover` as raw Git by searching for the word `git`. The usage/validation action labels also distinguished wording rather than recovery behavior. The invalid pilot is retained separately and never pooled with the fresh matrix.

After the independent product fix, actual sandbox recovery preflight passed both affected cases on fresh fixtures. The first `index rebuild` preflight exposed the separate `/var` versus `/private/var` Index namespace permission mismatch; the corrected preflight passed. These are environment equivalence gates, not agent recovery outcomes.

The fresh matrix under plan `c9a50cdbb0e7f0602a41b6e1a6ce9a6e6e6d6941` completed all 18 sessions. Independent oracle: S 9/9, P 9/9; runtime failure, timeout, parse failure, forbidden action, and tool-budget hit: zero. Both arms had one additional CLI error in `transitionPending` before supported recovery. S total agent runtime was 560.689 s and 1,198,379 reported input+output tokens; P was 566.904 s and 1,108,187 tokens. These exclude operator, gate, CI, integration, and report work; cost and whole-cycle tokens are unmeasured. One trial per case and arm supports no p95 or general performance/token reduction claim. See `artifacts/trial-analysis.md` and per-session records.

## Conclusion

The tested structured fields were sufficient for correct recovery or safe stop in all nine S cases. P also passed all nine. This is a narrow correctness observation, not a decision about long-term category/exit allocation or envelope versioning. Decision Review remains; the ADR stays `Spike Required` until that review.

## Artifacts

`artifacts/error-cases.json` fixes initial failures, source/binary identity, and case oracles. `artifacts/recovery-actions.json` fixes action labels, expected completion/human decisions, and prohibited actions. `artifacts/invalid-pilot/` retains all excluded records; `artifacts/preflight/` contains the actual sandbox gate and the failed setup diagnosis; `artifacts/harness/` contains the proxy, prompt, preflights, independent oracle, and frozen trial launcher. `artifacts/trial-analysis.md`, `artifacts/trial-matrix.json`, and `artifacts/trials/` contain the fresh analysis and bounded machine event records. Private agent reasoning and prose conversation are not committed.
