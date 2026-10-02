# Repository Profile v1 and v2

Product-specific mappings live in a tracked, regular file in the Product Git repository. The authoritative read-only command is:

```text
hamii --project HAMII_ROOT integration plan SCREEN_ID \
  --product-repository PRODUCT_ROOT --repository-profile RELATIVE_PATH --json
```

Both options are required. `PRODUCT_ROOT` must be the Git worktree root. `RELATIVE_PATH` is a safe path from that root to a tracked regular file; absolute paths, `..`, symlinks, submodules, and missing or untracked files are rejected. The Product worktree must be clean, including staged, unstaged, and untracked files. hamii reads the Profile bytes from the exact `HEAD` Git blob, checks that the Product commit and clean status remain unchanged during capture, and verifies that its own Canonical observation is still current. The command only reads both repositories.

The resulting `repositoryProfileReceipt` identifies the Product commit, tracked Profile path and blob, exact Profile bytes, hamii Document and state observation, Screen, and semantic contract. A Product branch name is not its identity: the same clean commit can be checked out through another branch. Any new Product commit, including a documentation-only commit, invalidates a prior receipt until a new plan is captured. The receipt proves the inputs used for **planning**; it does not authorize a Product source patch.

The existing `hamii integration plan SCREEN_ID --integration-profile PATH --json` continues to read an explicitly selected external **v1** file without writing it. This is a **non-authoritative read-only plan**: it emits no `repositoryProfileReceipt` or `repositoryMappingEvidence` and cannot authorize a future Product patch. hamii does not discover, edit, or migrate that file. To make an existing external v1 file authoritative, its bytes must be adopted through a reviewed Product repository commit; this command does not perform adoption. Neither Profile mode stores Product-specific mappings in hamii Core IR or in a hamii Canonical shard. The Document's `versions.integrationProfile` stays at `1` for both Product Profile v1 and v2; the Profile file has its own `formatVersion`.

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

Product Profile v2 retains the v1 fields for decoding but uses a typed locator as the sole target authority for a supported source mapping. Do not also place a free-string target for that key in a structural map. Each `sourceLocators` key identifies a required mapping as `kind:semanticID`, for example `input:user.name` or `event:editTapped`. The first typed locator supports only a directly written, unconditional stored property or enum case inside one top-level Swift nominal declaration:

```json
{
  "formatVersion": 2,
  "repositoryName": "Product",
  "architectureRules": [],
  "componentMappings": [],
  "tokenMappings": [],
  "assetMappings": [],
  "routingMappings": {},
  "stateMappings": {},
  "nativeMappings": {},
  "codeModificationPolicy": [],
  "sourceLocators": {
    "input:user.name": {
      "kind": "swiftDirectDeclaration",
      "path": "Sources/ProductUser.swift",
      "enclosingKind": "struct",
      "enclosingName": "ProductUser",
      "memberKind": "storedProperty",
      "memberName": "displayName"
    }
  }
}
```

Only the authoritative Product Git mode accepts v2. It returns `repositoryMappingEvidence` in deterministic mapping-key order alongside the plan and receipt. `verified` with `scope: "pinnedSourceDeclaration"` means exactly one expected-kind declaration exists in the pinned regular Swift Git blob under the supported syntax. The resolved plan carries a locator-derived label, not a verified free-string target. Evidence does **not** establish membership in a selected Product build, type compatibility, route behavior, asset resolution, runtime behavior, or permission to publish a patch. Unsupported conditional, extension, overload, nested/local, macro-generated, resource, token, and Native constructs return `unverifiable` until supported by separate evidence. For a required key, no locator or structural value produces `missingMapping`; a blank structural value without a locator produces `emptyMapping`; a nonempty structural value without a locator produces `unverifiable` evidence and `invalidMapping`; a locator together with a structural value produces `duplicateMappingAuthority` evidence and `invalidMapping`. Missing source declarations, ambiguous or wrong-kind declarations, invalid paths, and stale observations fail closed. Profile v1 has no source evidence and remains structural-only even in authoritative mode. Profile v1→v2 needs reviewed Product-specific locator input; there is no automatic conversion of free strings.

`RepositoryBuildSelection` and `RepositoryBuildEvidence` are typed models for a separate selected-build check. An internal pure join classifies a normalized executed compiler input inventory; it does not authenticate that inventory. Production has no adapter that acquires both protected source bytes and authentic invocation evidence. The current CLI has no build-membership option or `repositoryBuildEvidence` field; `selectedBuildMember` cannot be obtained from it. The strongest current positive is `pinnedSourceDeclaration`. Internal build-membership evaluation without protected acquisition is `unverifiable`, and unverified source evidence is `sourceNotVerified`. A successful Xcode build, a read-only disk image, matching pre/post source hashes, or parsed SwiftFileList/build log text alone cannot authorize a positive. A tested same-UID setup permitted source-path substitution; controlled evidence-channel tests showed that text/file-list records could be forged. These tests did not observe a malicious compiler-time substitution or forged Xcode execution trace. The existing integration plan's success means only that planning resolved.

A resolved plan returns exit 0. Unresolved mappings or relations return exit 5 with `category: "contract"` and structured `integrationPlan`, `resolutionIssues`, and `blockedOutputs`. Authoritative v2 also returns source evidence for required mappings, including unresolved ones. `ok: true` or `needsResolution: false` means that this planning gate passed, not that a Product patch is authorized. Unsupported Profile or Document version returns exit 6 / `migrationRequired`; malformed Profile content returns exit 5 / `contract`. Authoritative capture also rejects dirty/stale observations with `conflict`, an invalid Git repository or inaccessible Git object with `git`, and a missing or non-regular tracked Profile with `contract`. The CLI error contract defines the structured categories.
