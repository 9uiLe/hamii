# Canonical Format v1 layer baseline

`format-v1-layer.json` was encoded by the production `Layer` from source commit
`e652031ea92fdd6a51997818bc4590389b40a90a` using the Canonical JSON encoder
settings (`sortedKeys`, `prettyPrinted`, `withoutEscapingSlashes`, trailing LF).

SHA-256: `0ea0d46d3f78f83de37f6586ed7e6215851b24f14d5ea3deeca3012f7a838d80`

The fixture covers all seven Format v1 layer kinds, binding and fallback, event,
asset reference, stack layout and tokens, multi-child scroll, nested component
slot content, interaction, accessibility, native intent, target overrides, and
a currently accepted cross-kind asset reference. The test requires exact bytes
for both construction and decode/re-encode.

`format-v1-project/` was written by `CanonicalRepository` built from the same
pre-refactor commit. It contains a Screen, two nested ComponentDefinitions, Asset, Scope,
manifest, and agent profiles. The local `.hamii/` coordination records are
excluded because they are not Canonical Project Data.

- Pre-refactor `CanonicalSnapshot.identity`:
  `e0bb7311812a2a4f194456cced0f1cbfb73fd59b3570fc3f4e04672c560c3d9a`
- Screen shard SHA-256:
  `6ddadd8716ecefc5698f91fdc1cd212956c55b5a05e02eb0b1d4889e4f6e00ad`
- Badge Component shard SHA-256:
  `13b80669ab54505b5d3dfe94c4b52189b5a5eb00868539fb4623a5e067957dfd`
- Leaf Component shard SHA-256:
  `3f381249c8e93b582071cc023579254eb43d38090eb35007f8407791d8a3cbbe`

The project test copies these exact files to a temporary root, observes the
current loader and typed model, compares Screen/Component re-encoding byte for
byte, then verifies a no-op semantic mutation leaves all seven shards, the
Snapshot identity, coordinated generation, and client precondition unchanged.
