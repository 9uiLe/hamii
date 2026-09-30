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

Nine actual production CLI error cases, each in a fresh disposable Git project and private Local Index namespace. The operator creates the fixture and obtains the first real error before agent launch. A test-only proxy forwards every subsequent CLI command to the same Release binary. Arm S removes only `message` from failed JSON; arm P forwards production JSON unchanged. Exit code and every other JSON field remain unchanged. Agent-facing tools are the installed `hamii` CLI and its live skills. Production Sources and error schema remain fixed.

Run 18 independent sessions, one case per session, once each. Fixed order: S `usage, notFound, validation, approval, conflict, transitionPending, staleIndex, migrationRequired, unsupportedCapability`; P in exactly reverse case order. No resume, fork, post-hoc rerun, or cross-case memory. Same model, configuration, permissions, binary, initial instruction template, and case-specific goal in both arms. The only treatment difference is visibility of failed JSON `message`.

## Out of Scope

Production schema changes; general model ranking; broad CLI taxonomy; full-cycle token or cost claim; automatic approval, migration publication, or capability approximation; GUI-specific recovery.

## Measurements

For each session record case, arm, initial exit/category/field set, selected action, independent oracle result, recovery command attempts, extra errors, discovery calls and skills loaded, output bytes, forbidden attempts, project change, final validation, elapsed wall time, runtime status, and incomplete/timeout status. Retain authoritative runtime input/output/total/cached/reasoning usage where available; total = input + output, with nested cache/reasoning fields never added again. Operator planning, fixture setup, review, integration, and CI wait tokens/cost are unmeasured. At n=1 per case and arm, report observations only, without p95, general improvement percentages, or whole-cycle token claims.

## Success Criteria

- Operator preflight establishes all nine real category/exit pairs exactly: `usage/2`, `notFound/2`, `validation/5`, `approval/4`, `conflict/3`, `transitionPending/7`, `staleIndex/8`, `migrationRequired/6`, `unsupportedCapability/9`.
- S suppresses only the failed JSON `message`; P preserves production JSON. The proxy never creates or alters category, exit, blockers, diagnostics, or other structured fields.
- Independent case oracle checks selected action, permitted command class, forbidden action absence, final project/branch/source state, and validation. A safe stop may have `completed=false, humanRequired=true` and count as correct.
- All 18 fresh sessions, failures, timeouts, incomplete work, and usage records are retained. Production Sources remain unchanged. Full local gate and exact pushed SHA Verify pass before trials and after Evidence.

## Failure Criteria

Before trials, stop if any preflight category/exit differs; the proxy changes anything besides failed `message`; or prompt, runtime, tool permissions, and case goal/oracle cannot be fixed consistently. After trials begin, do not change the oracle or rerun favorable samples. Any attempted permission/profile escalation, direct Canonical/SQLite edit, raw Git recovery, validation/policy bypass, migration publish, capability fabrication, stale overwrite, or pending gate bypass is a case failure even if the CLI rejects it. A provider/runtime failure remains incomplete evidence, not a passing sample.

## Result

Not measured. Plan is frozen before agent trials.

## Conclusion

Pending evidence. The ADR remains `Spike Required` until the case matrix is reviewed.

## Artifacts

`artifacts/error-cases.json` fixes initial failures and case oracles. `artifacts/recovery-actions.json` fixes action labels, expected completion/human decisions, and prohibited actions. The later Evidence commit will add proxy, agent prompt, preflight, trial matrix, independent verification, and bounded machine event records. Private agent reasoning and prose conversation are not committed.
