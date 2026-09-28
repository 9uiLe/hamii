# Dependency boundary evidence

## Observed module graph

`swift package dump-package` reports zero target dependencies for both `HamiiMigrations` and the test-only `HamiiMigrationBoundarySpike`. The latter lives in `Tests/MigrationBoundarySpike/`, imports Foundation only, and accepts/returns `[String: Data]`; it neither accepts nor returns a Current Core `Document`. `HamiiTests` depends on both the probe and the current Core/Format/Index targets. Only this outer test target adapts candidate bytes for a current-v1 semantic oracle and builds a fresh LocalIndex.

`Sources/HamiiMigrations/MigrationPreflight.swift` imports Foundation only. No source under `Sources/HamiiCore`, `Sources/HamiiFormat`, or `Sources/HamiiIndex` imports `HamiiMigrations` or `HamiiMigrationBoundarySpike`. Existing `HamiiFormat`→`HamiiCore` and `HamiiIndex`→`HamiiFormat`/`HamiiCore` dependencies remain current-system dependencies. Text search of these modules found no v2/v3 document-format parser or migration edge. Other identifiers containing `legacy` in Core/Format refer to capability aliases or snapshot comparison, not this historical parser prototype; they were outside this decision.

## What the test establishes

The independent target resolves 1→2, 2→3, direct 1→3, and 3→3. It rejects unknown target and downgrade. The v1→v2 edge relocates `layout.paddingTokenID` to a test-only ordered padding effect, including nested ComponentInstance and slot content. The v2→v3 edge only advances both document version markers. The validator callback runs after each edge. Three runs and direct/stepwise 1→3 produced identical candidate bytes. Deterministic failures at either edge and an intermediate-v2 validator failure returned no candidate. The original ten Canonical JSON files remained byte-identical. All untouched files, including the independent agent-profile file, passed through byte-for-byte.

The outer harness adapted candidate v2/v3 bytes back to current v1 solely to compare the complete `Document` and run the current semantic validator. That equality covers stable IDs, Page/AppSurface and Screen references, nested Component references, Scope ownership, Token and Asset references in this fixture. It then initialized a fresh Git repository, rebuilt a new LocalIndex from a coordinated snapshot, and queried the expected `Outer` component usage count of 1.

## Limits

This is a test-only edge graph. The current production Format remains v1 and no production v2/v3 parser, migration distribution, approval workflow, index handoff for a real v2 reader, or historical-format package has been shipped. The test-side v1 adapter is an oracle for preservation of currently representable semantics; it is not evidence that a production v2 reader accepts or executes ordered effects. The isolated target shows a viable dependency shape, not a complete migration product.
