# Operator preflight: Index namespace permission mismatch

This is a failed **environment preflight**, not an agent trial or structured-error outcome. It ran after the independent Git subprocess fix at `956508865b774eea191f827d87e92f87c8f28893`.

- `transitionPending`: actual Codex workspace-write sandbox `hamii git recover` succeeded, exit 0, pending marker cleared.
- `staleIndex`: `hamii index rebuild` returned exit 7, category `index`, diagnostic `SQLite index: attempt to write a readonly database`. No stale result was served.
- The launcher permitted the hash of the Python-resolved `/private/var/.../project` path: `67694f64188eb48c4d4cd3a76e7b4fc136665cdeec931360f41c6ebe14b6ca86`.
- The actual `LocalIndexLocation` directory was hashed from the Swift-visible `/var/.../project` path: `260edefd94352e7f754f95c6a23f46ac37c267bf08a942d702f16640de4257b0`.
- The actual directory contained `index.sqlite`; the permitted directory was empty. The two paths resolve to the same worktree but produce different derived Index namespace keys.

The harness now grants the exact namespace used by `LocalIndexLocation`. A new fixture and new Codex process passed both recovery preflights; the accepted run is recorded in `actual-sandbox-preflight.json`. The failed run is retained here as a setup failure and is excluded from the recovery comparison.
