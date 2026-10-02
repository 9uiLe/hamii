# Typed Locator and Compiler Cross-check

## Related Decision

[Product Mapping Locator](../../ADR.md): whether a Product-root-relative tracked regular blob plus enclosing declaration, expected kind, and member path is sufficient for a conservative source-declaration locator, and what evidence would permit a `verified` result.

## Hypothesis

A typed Swift syntax resolver can fail closed for direct, unconditional Product declarations from pinned Git blobs. Cross-checking its accepted targets against compiler identities in the matching Product build context will reveal whether this tuple is sufficient for the stated subset. Unsupported conditional, extension, overload, generated, and resource cases must remain `unverifiable` unless separately proven.

## Questions

- Do typed syntax matches for Team MINO `Profile.nickname`, `Profile.createdAt`, edit action, and route correspond to one expected-kind compiled declaration each?
- Does the same hold for a direct declaration in Food Truck or SyncUps?
- Can duplicate names, wrong kind, moved/renamed files, conditional declarations, extensions, overloads, macros, and invalid paths be rejected without false `verified`?
- What Product module/SDK/build settings and generated artifacts are required for the compiler cross-check, and how much do they cost?

## Prototype Scope

Read only pinned, clean Product Git objects. Implement a disposable typed syntax resolver for the narrow direct-declaration subset and independently compare accepted candidates with compiler graph/index evidence from matching pinned Product source. Keep scratch builds and negative fixtures outside Product worktrees and hamii Canonical data. Record exact commit, blob, toolchain, commands, pre/post Product status, and trial counts.

## Out of Scope

Production Profile v2 codec, production validator, Product patching, runtime semantics, semantic I03 conflict detection, and universal Swift/source resource support.

## Measurements

The [typed resolver results](artifacts/typed-resolver-results.json) contain 23 asserted cases, each run once with Apple Swift 6.4 on this macOS host. Five pinned direct declarations yielded a unique **syntax candidate**. The first candidate took 275.52 ms; subsequent direct candidates took 77.97–93.85 ms in this process. These are probe costs, not Product or production validation latency. The [fail-closed audit](artifacts/fail-closed-audit.md) records an independent same-byte conditional-compilation experiment and source-identity controls.

The [Product compiler cross-check](artifacts/compiler-crosscheck.md) built the pinned Team MINO `Domain`/`FeatureProfile` and Food Truck `FoodTruckKit` iOS Simulator package modules from immutable Git archives. One local build trial per module set took about 27.9 s for FeatureProfile including dependencies and 27.7 s for FoodTruckKit. Three warm symbol-graph extraction trials ranged from 0.108–0.120 s for Domain, 0.277–0.287 s for FeatureProfile, and 0.575–0.735 s for FoodTruckKit. Cold extraction was much slower. These are environment-specific component costs; no end-to-end production validator timing is established.

## Success Criteria

Every accepted direct-declaration locator maps to exactly one expected-kind declaration in pinned source and matching Product compiler evidence. Negative and unsupported cases fail closed. Clone/relocation and pre/post Product bytes/status are checked. Costs and prerequisites are measured with explicit conditions.

## Failure Criteria

A syntax candidate is labeled `verified` without a matching Product compiler declaration, a wrong/ambiguous target is accepted, a source outside the pinned regular Git tree influences evidence, or required build settings cannot be established while claiming Product identity.

## Result

The typed syntax probe read exact regular Git blobs from pinned Team MINO and Food Truck commits. It returned `candidateUniqueSyntax` for Team MINO `Profile.nickname`, `Profile.createdAt`, `ProfileMainAction.tapEditProfile`, `ProfileRoute.profileSetup`, and Food Truck `User.authenticated(username:)`. Its controlled duplicate, wrong-kind, deleted/renamed/moved, invalid-path, stale-commit, conditional, extension, overload, nested, and malformed inputs returned non-verified outcomes. All 23 expected outcomes matched. The in-memory changed-tree cases are controls, not commits to the Product repositories.

The independent audit showed that the same pinned Swift source bytes compile to different declarations under different `-D` conditions. Food Truck itself has an `EXTENDED_ALL` conditional declaration and configurations with different active compilation conditions. Exact source existence therefore does not establish selected Product build membership. The syntax probe does not type-check and never emits `verified`.

The compiler cross-check found matching graph kind and precise compiler ID for seven declarations in the actual pinned Product package modules and selected iOS Simulator configurations: Team MINO `Profile.nickname`, `Profile.createdAt`, `ProfileMainAction.tapEditProfile`, `ProfileMainNav.pushProfileSetup`, `ProfileRoute.profileSetup`; Food Truck `User.authenticated(username:)`, `AccountStore.currentUser`. Exact Git blobs matched archived source bytes. A second build location reproduced complete `(pathComponents, kind, USR)` graph sets for Domain 566/566, FeatureProfile 1851/1851, and FoodTruckKit 5991/5991. An extraction without a built `FeatureProfile.swiftmodule` failed. This proves the selected compiled declarations under measured conditions, not all target configurations, runtime action/route semantics, or resource identity. It does not prove that a production resolver has securely bound every transitive compiler input to the pinned tree.

No production Profile schema, validator, or Product source write is introduced by this Spike.

## Conclusion

The tested direct-declaration locator can identify a unique pinned **source candidate** and reject the tested unsupported or malformed cases. Compiler evidence from the selected Product target and configuration is a distinct prerequisite for a Product-compiled `verified` claim. For the measured targets, such compiler evidence is obtainable, but it requires a matching build, module name, SDK, and flags. The ADR remains `Spike Required` while the option comparison and minimum Profile schema are assessed. A future validator must explicitly scope `verified` to the evidence it actually holds.

## Artifacts

- [Typed resolver probe](artifacts/typed-resolver.py) and [23-case result](artifacts/typed-resolver-results.json)
- [Independent fail-closed audit](artifacts/fail-closed-audit.md)
- [Product compiler cross-check](artifacts/compiler-crosscheck.md) and [machine-readable results](artifacts/compiler-crosscheck.json)
