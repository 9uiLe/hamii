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
pre-refactor commit. It contains a Screen, ComponentDefinition, Asset, Scope,
manifest, and agent profiles. The local `.hamii/` coordination records are
excluded because they are not Canonical Project Data.

- Pre-refactor `CanonicalSnapshot.identity`:
  `02196c93723e3fc19c1eb19253079993d44888a8a545c8469b728390e8334f0a`
- Screen shard SHA-256:
  `6ddadd8716ecefc5698f91fdc1cd212956c55b5a05e02eb0b1d4889e4f6e00ad`
- Component shard SHA-256:
  `faf5bdc3a27c6ae685b9f0ed5396aa95cf0e6dfe3f9b17ca935a4b616d76468a`

The project test copies these exact files to a temporary root, observes the
current loader and typed model, compares Screen/Component re-encoding byte for
byte, then verifies a no-op semantic mutation leaves all six shards, the
Snapshot identity, coordinated generation, and client precondition unchanged.
