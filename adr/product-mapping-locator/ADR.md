# Product Mapping Locator

## Context

An authoritative `RepositoryProfileReceipt` pins one Product commit and Profile blob to one hamii observation. Profile v1 mapping values are free strings. A nonempty value can satisfy structural planning but does not identify a Product declaration or resource with machine-verifiable meaning. [Product Integration Contract](../product-integration-contract/ADR.md) owns the later Product validation gate; [Repository Profile Persistence](../repository-profile-persistence/ADR.md) owns Product Profile placement and receipt identity. This ADR selects the first typed locator for read-only Swift source-declaration validation. Resource and Native semantics require their own typed evidence before they can be source verified.

## Decision to Make

What is the smallest Product-owned Profile mapping locator schema that uniquely and reproducibly identifies an explicitly written, direct Swift declaration of an expected kind within a pinned Product commit?

## Constraints

- Product architecture, source paths, model/action/route names, and compiler identities remain outside hamii Core IR.
- Profile format version is independent of Document format v3.
- Profile v1 free strings remain valid for external and authoritative **structural-only** planning; they do not become source-verified or patch-authorizing locators by reinterpretation.
- Zero or multiple matches, wrong declaration kind, invalid path, stale receipt, and unprovable lookup fail closed. Locator resolution reads immutable Git objects and does not modify the Product worktree.
- `verified`, `missing`, `ambiguous`, `invalidLocator`, `kindMismatch`, and `unverifiable` are distinct source-evidence outcomes. `verified` must carry its evidence scope: pinned **source declaration existence** is not selected Product build membership or runtime behavior. A missing Profile key remains `missingMapping`; a present but nonexistent target is `invalidMapping`. `conflictingMapping` from semantic behavior such as I03 is a separate Product audit result.
- This decision does not choose Product patch generation/publication, runtime behavior validation, or Product build policy beyond measuring locator prerequisites.

## Options

1. Qualified semantic symbol without a file path.
2. Tracked Product-root-relative file path plus declaration kind and enclosing/member path.
3. Compiler/index identity such as USR, symbol graph, or IndexStore identity.

Git line numbers and raw substring matches are evidence controls, not source authority candidates.

## Current Hypothesis

**Tentative implementation hypothesis:** A strict typed parser over the receipt-pinned regular Git blob can establish the restricted source-declaration claim without a Product build. Its output must stay `unverifiable` whenever the parser cannot prove direct, unconditional, unique membership. The locator choice itself is recorded under Decision; this hypothesis concerns the production validation mechanism.

## Unknowns

- How to bind all transitive compiler inputs to a pinned Product commit before claiming that a source declaration is included in a selected Product target/configuration. This is outside the first source-existence result.
- How to represent assets, tokens/resources, and Native capabilities with separate kind-specific locators. The first Swift variant returns `unverifiable` for these meanings.
- The production parser, receipt revalidation, concurrent Product HEAD/worktree observation, and end-to-end validator cost.
- Which reviewed Product Profile v1→v2 migration input supplies the new Product-specific path and declaration kinds. No v1 free string is converted by inference.

## Required Evidence

Compare all options against Team MINO iOS commit `dca2202f4be21869190d19bbcf223eb8646a2acd` and at least one other pinned Product repository. Record exact source files and candidate locators. Exercise duplicate names, deletion, file move, symbol rename, wrong kind, commit change, exact clone/relocation, symlink/path traversal, and internal/member/enum-case constructs. Measure build/index requirements, environment dependencies, and lookup cost with conditions and trial count. Keep controls and prototypes under focused Spikes: [qualified semantic symbol](spikes/qualified-semantic-symbol/SPIKE.md), [tracked file declaration](spikes/tracked-file-declaration/SPIKE.md), [compiler/index identity](spikes/compiler-index-identity/SPIKE.md), and [typed locator/compiler cross-check](spikes/typed-locator-crosscheck/SPIKE.md).

## Decision Criteria

Prefer a locator that identifies exactly one expected-kind target from the pinned commit, rejects stale/ambiguous/malformed evidence, is independent of absolute checkout path, and is practical for common Product constructs. Account separately for initial complexity, file move/rename UX, build/index cost, and future extension. If none meets this boundary, leave the decision open and narrow the missing evidence. A later implementation must emit typed source evidence separately from structural `IntegrationMappingStatus` and keep Profile v1 structural-only.

## Decision

Use a Product-owned, independently versioned Profile v2 tagged locator variant named conceptually `swiftDirectDeclaration`. Its minimum fields are a canonical Product-root-relative path to a tracked regular Swift Git blob; the kind and name of one top-level enclosing nominal; and the expected kind and name of one member declared directly in that nominal. The first supported member kinds are an explicitly written stored property and enum case. The authoritative receipt supplies the exact Product commit and Profile blob identity; resolution uses that commit's Git tree/blob bytes, never an unpinned worktree file. A file move or declaration rename requires a reviewed Profile update.

For a v2 mapping key, the typed locator is the sole source-target authority. A parallel free-string mapping for that same key is a duplicate authority and must be rejected for that mapping; a free string alone is structural input and cannot become source-verified. A required key with neither target is missing; a blank free string remains empty. This prevents verification of one declaration from making an unrelated string target appear verified. The Planner may use a nonempty locator-derived internal marker after verification, but no consumer may parse that marker as Product code.

For the first variant, `input` and semantic `source` mappings expect a stored property; an `event` mapping expects an enum case. A Profile cannot select a different member kind to redefine the contract's expectation. Token, asset, Native, and other meanings remain outside this Swift declaration subset.

The first `verified` outcome means **exactly one expected-kind declaration exists in the pinned source blob under this restricted syntax**, with an explicit `pinnedSourceDeclaration` evidence scope. It does not mean the declaration is present in a selected Product target, that a reducer/route uses it, that a resource resolves in a bundle, or that a patch may be published. A unique parser candidate is not enough if parsing is incomplete or the construct is conditional, generated, in an extension, nested/local, overloaded, or otherwise outside the supported subset; return `unverifiable`. Zero, multiple, wrong-kind, malformed/nonregular path, and stale receipt cases fail closed with distinct typed outcomes. Resource, token, and Native mapping kinds are not reinterpreted as Swift declarations and remain `unverifiable` until a separate typed variant has evidence.

Compiler/index identities are optional corroborating evidence for a **different**, selected-build claim. Such a claim requires explicit Product target/module/configuration and compiler inputs tied to the pinned source tree; an absolute source URI or USR alone is not authority. The first read-only validator does not require a Product build and must not claim selected-build verification. Profile v1 strings remain structural-only for external and authoritative planning. A v1→v2 upgrade requires reviewed Product-specific locator input, not automatic migration or runtime aliases. Profile versioning remains independent of Document format v3.

**Why this option:** A pathless qualified name was ambiguous across modules and did not reliably cover conditional or non-Swift targets. Bare compiler identity was sensitive to module naming and required a compiled Product context; the same USR survived a changed commit, so it did not establish source freshness. The tracked-file tuple gave a unique candidate for five direct declarations across Team MINO and Food Truck, and 23 typed syntax cases rejected the tested malformed/unsupported conditions. Actual pinned iOS Simulator Product package builds independently confirmed seven selected declarations and reproduced complete graph triples after relocation. These observations support the restricted source locator; they do not prove all transitive build inputs, every Swift construct, or runtime behavior. See the four Spikes under Required Evidence.

**Implementation gate:** Build the Profile v2 codec and read-only validator in the integration boundary, with a strict typed parser for the supported subset, immutable Git blob capture, receipt checks before and after validation, typed evidence, and Planner/CLI projection. Preserve v1 structural planning. Product source writes, build membership, resource identity, and semantic conflict detection remain outside this slice. If the production parser cannot safely establish the restricted source claim, return `unverifiable` rather than broadening the meaning of `verified`.

## Status

Implementation Required
