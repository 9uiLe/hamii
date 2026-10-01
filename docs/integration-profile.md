# Repository Profile v1

Product-specific mappings live in a tracked, regular file in the Product Git repository. The authoritative read-only command is:

```text
hamii --project HAMII_ROOT integration plan SCREEN_ID \
  --product-repository PRODUCT_ROOT --repository-profile RELATIVE_PATH --json
```

Both options are required. `PRODUCT_ROOT` must be the Git worktree root. `RELATIVE_PATH` is a safe path from that root to a tracked regular file; absolute paths, `..`, symlinks, submodules, and missing or untracked files are rejected. The Product worktree must be clean, including staged, unstaged, and untracked files. hamii reads the Profile bytes from the exact `HEAD` Git blob, checks that the Product commit and clean status remain unchanged during capture, and verifies that its own Canonical observation is still current. The command only reads both repositories.

The resulting `repositoryProfileReceipt` identifies the Product commit, tracked Profile path and blob, exact Profile bytes, hamii Document and state observation, Screen, and semantic contract. A Product branch name is not its identity: the same clean commit can be checked out through another branch. Any new Product commit, including a documentation-only commit, invalidates a prior receipt until a new plan is captured. The receipt proves the inputs used for **planning**; it does not authorize a Product source patch or prove that mapped Swift symbols exist. Product source analysis and patch publication require separate validation.

The existing `hamii integration plan SCREEN_ID --integration-profile PATH --json` continues to read an explicitly selected external file without writing it. This is a **non-authoritative read-only plan**: it emits no `repositoryProfileReceipt` and cannot authorize a future Product patch. hamii does not discover, edit, or migrate that file. To make an existing external v1 file authoritative, its bytes must be adopted through a reviewed Product repository commit; this command does not perform adoption. Neither Profile mode stores Product-specific mappings in hamii Core IR or in a hamii Canonical shard. The Document's `versions.integrationProfile` and the Profile's `formatVersion` must both be `1`.

```json
{
  "formatVersion": 1,
  "repositoryName": "Product",
  "architectureRules": [],
  "componentMappings": [],
  "tokenMappings": [],
  "assetMappings": [],
  "routingMappings": {},
  "stateMappings": {"user.name": "User.displayName"},
  "nativeMappings": {},
  "codeModificationPolicy": []
}
```

The three maps keyed by `EntityID` use the v1 Swift `Codable` representation: alternating key/value arrays. For example, `"assetMappings": [{"rawValue":"asset_avatar"}, "Product.Avatar"]`. `routingMappings`, `stateMappings`, and `nativeMappings` are JSON objects keyed by semantic name. `nativeMappings` may be absent in an existing v1 value; omission means an empty map. A present `nativeMappings` must be an object. All other listed fields are required. Duplicate JSON object keys or repeated `EntityID` mapping keys are invalid. Mapping keys and `repositoryName` cannot be blank. Mapping values may be blank in the file, but the planner returns `emptyMapping` and refuses to resolve them.

A structurally resolved plan returns exit 0. Unresolved mappings or relations return exit 5 with `category: "contract"` and structured `integrationPlan`, `resolutionIssues`, and `blockedOutputs`. This result says only that required semantic mappings are present and valid in the Profile; it does not establish Product symbol existence, type correctness, route behavior, or runtime fidelity. Version mismatch returns exit 6 / `migrationRequired`; malformed v1 content returns exit 5 / `contract`. Authoritative capture also rejects dirty/stale observations with `conflict`, an invalid Git repository or inaccessible Git object with `git`, and a missing or non-regular tracked Profile with `contract`. The CLI error contract defines the structured categories.
