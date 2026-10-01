# Repository Profile v1

`hamii integration plan SCREEN_ID --integration-profile PATH --json` reads the explicit file as a read-only input. The file is not a hamii Canonical shard. hamii does not discover, edit, or migrate it. The Document's `versions.integrationProfile` and the file's `formatVersion` must both be `1`.

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

A fully resolved plan returns exit 0. Unresolved mappings or relations return exit 5 with `category: "contract"` and structured `integrationPlan`, `resolutionIssues`, and `blockedOutputs`. Version mismatch returns exit 6 / `migrationRequired`; malformed v1 content returns exit 5 / `contract`. The profile file is an assertion of Product mapping, not proof that a named symbol exists in the Product repository. Repository analysis and Product runtime validation remain separate work.
