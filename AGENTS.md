# Repository development instructions

This repository uses `adr/` as a **working queue**, not an archive. Read only the ADR directories relevant to the task. The current architecture is documented in `docs/final-architecture.md`; production code must never depend on files under `adr/`.

## ADR and Spike rules

- Create `adr/<short-kebab-case>/ADR.md` for one unresolved architecture decision, meaningful technical uncertainty, difficult-to-reverse choice, or decision requiring a prototype/benchmark. Do not create ADRs for ordinary tasks or bugs. Directory numbers are not identifiers.
- `ADR.md` must contain Context, Decision to Make, Constraints, Options, Current Hypothesis (clearly tentative), Unknowns, Required Evidence, Decision Criteria, and Status. Allowed statuses: Open, Researching, Spike Required, Ready for Decision, Implementation Required.
- Add each experiment only under `adr/<decision>/spikes/<experiment>/SPIKE.md`; never put `SPIKE.md` beside `ADR.md`. One ADR may have zero or more focused Spikes. Each Spike must contain Related Decision, Hypothesis, Questions, Prototype Scope, Out of Scope, Measurements, Success Criteria, Failure Criteria, Result, Conclusion, and Artifacts. A Spike validates knowledge; its prototype is not automatically production code.
- Put Spike-specific results only in that Spike’s `artifacts/`; use ADR-level `artifacts/` only for evidence spanning the whole decision. Create either directory only when needed. Do not commit unnecessary generated files or large build outputs.
- One ADR has one decision boundary. If a Spike can support an independent decision, split the ADR. If several Spikes support one decision, keep them under that ADR. If work reveals a separate decision boundary, create a separate ADR. For partial completion, keep the ADR and narrow its remaining question. A decision without implementation remains in `adr/` with Status `Implementation Required`.

## Closing an ADR

Delete an ADR directory only after **all** are true: the decision is made, required research and any required Spike are complete, implementation and validation are complete, no follow-up remains, and the decision and Spike result already exist in Git history. Before deletion, move the enduring rule to production code/schema/validation/config/tests or current docs so those stand alone.

**Commit order is mandatory:** first commit the ADR with research, Spike result, and decision; then commit implementation; only in a later commit delete the ADR directory. Never create and delete an ADR in a single commit. A PR may group phases only when prior commits preserve this sequence; separate PRs are preferred for large decisions.

Git history is the archive. Do not retain resolved ADRs or obsolete Spike material in the working tree. Do not routinely pull deleted ADRs from Git history into AI context. The desired `adr/` state is `.gitkeep` only, but never remove an unresolved ADR to reduce the count.

For the full Human and AI workflow, see [docs/adr-workflow.md](docs/adr-workflow.md).

## Delivery verification

- After committing and pushing a change, find the GitHub Actions `Verify` run for the exact pushed commit SHA. Wait for its final conclusion without asking a human to check it.
- If `Verify` fails, inspect the failed step and logs, fix the cause, rerun local checks, commit and push the fix, then verify the new run. A successful local check or an earlier commit's green run does not establish the pushed commit's CI result.
- Report the run URL and conclusion together with the commit SHA. Check the working tree and remote tracking status before reporting completion.
- `python3 scripts/wait-ci.py --sha "$(git rev-parse HEAD)"` waits for the exact `Verify` run and returns a bounded JSON verdict. On failure, inspect that run's log and fix the cause.
