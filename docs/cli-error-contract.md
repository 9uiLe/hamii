# CLI structured errors

`hamii --json` is the automation interface. A failed one-shot command returns a JSON object with `ok: false` and a nonzero process exit status. `category` is the primary machine-readable error identity. The exit status is a coarse failure class, not a replacement for `category`. Optional structured fields such as `blockers`, `diagnostics`, and command-specific payloads provide detail when present; absence does not imply a default value.

| Exit | Current categories | Meaning |
| --- | --- | --- |
| 1 | `internal` | Unclassified failure |
| 2 | `usage`, `notFound` | Request or resource correction |
| 3 | `conflict` | Conflicting client or Canonical state |
| 4 | `approval`, `permission`, `profile` | Approval or authorization |
| 5 | `validation`, `contract`, `assetIntegrity` | Semantic validation, contract, or integrity |
| 6 | `migrationRequired`, `migration`, `alreadyCurrent` | Format or migration |
| 7 | `transitionPending`, `storage`, `git`, `index` | Transition or storage operation |
| 8 | `staleIndex` | Index freshness cannot be established |
| 9 | `unsupportedCapability` | Unsupported UI capability |

`integration plan SCREEN_ID --integration-profile PATH --json` reads only the explicit Repository Profile file. A resolved plan returns exit 0 and `ok:true`. Needs Resolution returns exit 5, `category:"contract"`, `ok:false`, and still includes `integrationPlan`, `resolutionIssues`, and `blockedOutputs`. A profile or Document integration-profile version mismatch returns `migrationRequired` / exit 6; malformed v1 profile content returns `contract` / exit 5. An unreadable explicit path returns `storage` / exit 7. The profile file is not a hamii Canonical shard.

`integration plan SCREEN_ID --product-repository ROOT --repository-profile RELATIVE_PATH --json` is the authoritative read-only planning path. Both options are required and cannot be combined with `--integration-profile`. Success and Needs Resolution retain the same plan fields and add `repositoryProfileReceipt`, which binds the exact Product commit/Profile blob and hamii observation. Missing or conflicting options return `usage` / exit 2; a non-repository root or unavailable Git object returns `git` / exit 7; dirty or changed Product state and stale hamii observation return `conflict` / exit 3; missing, untracked, symlink, non-regular, or malformed Profile input returns `contract` / exit 5; unsupported Profile or Document integration-profile version returns `migrationRequired` / exit 6. A typed capture failure also includes `repositoryProfileIssue.code` so automation need not parse `message`. `ok:true` only means that required semantic mappings are structurally resolved; Product symbols and runtime behavior are not validated here. The external Profile mode preserves its existing JSON shape and does not emit a receipt.

The optional `message` is a human-readable diagnostic. Automation must not parse its wording to choose a recovery action. Exit codes alone do not determine whether retry is safe. Obtain command instructions from the installed `hamii skills list` / `skills get` and inspect the category and available structured fields. For an unknown category, do not automatically mutate or retry; stop and surface the failure for review. The tested nine-category recovery matrix supports this contract for those cases only; it does not assign retry behavior to every category in the table.

`terminal`, when present, is a context-session transport signal. In that session, `usage` and `notFound` responses may be nonterminal; a terminal error ends the session. One-shot commands generally omit `terminal`, and omission does not mean `false`. See [Context session](context-session.md) for its request and resync rules.

The installed CLI version is the release boundary for this contract. Adding optional structured fields or a category for new semantics is compatible if consumers stop safely on unknown categories. Removing, renaming, or repurposing an existing category, changing an existing structured field's type or meaning, reallocating an existing category's exit status, or requiring a formerly optional field for safe interpretation is a breaking CLI change. It requires a CLI version change, explicit compatibility review, and a release note. Existing machine semantics remain stable until such a decision. There is no separate `errorSchemaVersion` or promised number of compatible releases.
