import Darwin
import Foundation
import HamiiCore
import HamiiApplication
import HamiiFormat
import HamiiIndex
import HamiiGeneration
import HamiiIntegration
import HamiiMigrations
import HamiiMigrationRuntime

private struct CLIError: Error, CustomStringConvertible {
    var category: String
    var message: String
    var description: String { message }
}

private struct MergeCheck: Encodable {
    let sourceHead: String
    let candidateHead: String
    let documentID: EntityID
    let documentRevision: Int
    let indexedCandidate: Bool
    let published: Bool
}

private enum ContextCLIOutput: Encodable {
    case summary(ContextResponse<ContextProjectSummary>)
    case layer(ContextResponse<ContextLayerDetail>)
    case resources(ContextResponse<ContextResourceList>)
    case componentAvailability(ContextResponse<ContextComponentAvailabilityList>)
    case component(ContextResponse<ContextComponentDetail>)
    case token(ContextResponse<ContextTokenDetail>)
    case surface(ContextResponse<ContextSurfaceCapabilityDetail>)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .summary(let value): try value.encode(to: encoder)
        case .layer(let value): try value.encode(to: encoder)
        case .resources(let value): try value.encode(to: encoder)
        case .componentAvailability(let value): try value.encode(to: encoder)
        case .component(let value): try value.encode(to: encoder)
        case .token(let value): try value.encode(to: encoder)
        case .surface(let value): try value.encode(to: encoder)
        }
    }

    var description: String {
        switch self {
        case .summary(let value): "\(value.payload.documentName) (revision \(value.observation.documentRevision))"
        case .layer(let value): "\(value.payload.layer.id.rawValue) \(value.payload.layer.name)"
        case .resources(let value): "\(value.payload.returnedCount) of \(value.payload.matchingCount) resources\(value.payload.truncated ? " (truncated)" : "")"
        case .componentAvailability(let value): "\(value.payload.returnedCount) of \(value.payload.matchingCount) component assessments\(value.payload.truncated ? " (truncated)" : "")"
        case .component(let value): "\(value.payload.id.rawValue) \(value.payload.name)"
        case .token(let value): "\(value.payload.id.rawValue) \(value.payload.name)"
        case .surface(let value): "\(value.payload.surfaceID.rawValue): \(value.payload.losses.totalCount) capability losses, preview \(value.payload.previewReady ? "ready" : "blocked")"
        }
    }
}

private struct Output: Encodable {
    var ok: Bool
    var category: String?
    var message: String?
    var blockers: [String]?
    var document: Document?
    var statePrecondition: ClientPrecondition?
    var mutation: MutationResult?
    var components: [ComponentDefinition]?
    var skills: [String]?
    var skill: String?
    var diagnostics: [Diagnostic]?
    var hits: [ComponentHit]?
    var generated: GeneratedSource?
    var contract: IntegrationContract?
    var integrationPlan: IntegrationPlan?
    var resolutionIssues: [IntegrationResolutionIssue]?
    var blockedOutputs: [SemanticOutputKey]?
    var migration: MigrationPlan?
    var migrationResolution: MigrationResolutionReport?
    var migrationReview: MigrationPreparedReview?
    var migrationPublication: MigrationPublicationResult?
    var previewPlan: TargetPlan?
    var mergeCheck: MergeCheck?
    var context: ContextCLIOutput?
    var terminal: Bool?
    init(ok: Bool, category: String? = nil, message: String? = nil, blockers: [String]? = nil, document: Document? = nil, statePrecondition: ClientPrecondition? = nil, mutation: MutationResult? = nil, components: [ComponentDefinition]? = nil, skills: [String]? = nil, skill: String? = nil, diagnostics: [Diagnostic]? = nil, hits: [ComponentHit]? = nil, generated: GeneratedSource? = nil, contract: IntegrationContract? = nil, integrationPlan: IntegrationPlan? = nil, resolutionIssues: [IntegrationResolutionIssue]? = nil, blockedOutputs: [SemanticOutputKey]? = nil, migration: MigrationPlan? = nil, migrationResolution: MigrationResolutionReport? = nil, migrationReview: MigrationPreparedReview? = nil, migrationPublication: MigrationPublicationResult? = nil, previewPlan: TargetPlan? = nil, mergeCheck: MergeCheck? = nil, context: ContextCLIOutput? = nil, terminal: Bool? = nil) {
        self.ok = ok; self.category = category; self.message = message; self.blockers = blockers; self.document = document
        self.statePrecondition = statePrecondition
        self.mutation = mutation; self.components = components; self.skills = skills
        self.skill = skill; self.diagnostics = diagnostics; self.hits = hits
        self.generated = generated; self.contract = contract; self.integrationPlan = integrationPlan
        self.resolutionIssues = resolutionIssues; self.blockedOutputs = blockedOutputs
        self.migration = migration
        self.migrationResolution = migrationResolution; self.migrationReview = migrationReview
        self.migrationPublication = migrationPublication
        self.previewPlan = previewPlan
        self.mergeCheck = mergeCheck
        self.context = context
        self.terminal = terminal
    }
}

private enum CLI {
    static let version = "0.1.0"
    static let skillTexts: [String: String] = [
        "bootstrap": "hamii \(version)\nUse hamii skills list and hamii skills get NAME. Load only the relevant live skill. Global options: --project PATH --json. Create a Git-backed project with hamii init NAME --project PATH --json; inspect it with hamii inspect --project PATH --json. Do not guess commands or edit canonical files directly. Supply the statePrecondition from inspect as --state TOKEN for every mutation.",
        "authoring": "hamii \(version)\nGlobal options: --project PATH --profile NAME --json. Inspect: hamii inspect. Mutations require --state TOKEN from inspect or the previous mutation. Commands: page create NAME; scope create PARENT_ID NAME; screen create SCOPE_ID NAME; target add PLATFORM FRAMEWORK; surface add PAGE_ID SCREEN_ID TARGET_ID DEVICE RUNTIME BUILD_ENVIRONMENT; surface target SURFACE_ID TARGET_ID; capability set TARGET_ID KEY SUPPORT; layer add SCREEN_ID PARENT_ID KIND NAME TEXT; layer text SCREEN_ID LAYER_ID TEXT. Managed git switch BRANCH requires a clean worktree and --state TOKEN; git recover validates an interrupted switch or merge publication. git merge check BRANCH --state TOKEN validates an isolated candidate without publishing. git merge publish BRANCH --state TOKEN validates and publishes a candidate through the coordinated pending gate. Use - for no text. Read the tokens, components or assets skill when needed. All mutations use the same Authoring Harness validation as GUI.",
        "tokens": "hamii \(version)\ntoken create OWNER_SCOPE_ID NAME KIND LITERAL --state TOKEN creates a primitive token; token alias OWNER_SCOPE_ID NAME KIND TARGET_TOKEN_ID --state TOKEN creates a semantic alias. KIND is color|typography|spacing|radius|border|shadow|opacity|motion. Spacing literals are nonnegative finite numbers. layer token SCREEN_ID LAYER_ID spacing|padding TOKEN_ID|- --state TOKEN sets or clears a layout token. ArchitectureScope ownership and token references are validated before save.",
        "components": "hamii \(version)\ncomponent list CONSUMER_SCOPE_ID; component create OWNER_SCOPE_ID NAME --state TOKEN; component instantiate SCREEN_ID PARENT_LAYER_ID DEFINITION_ID --state TOKEN; component promote DEFINITION_ID ANCESTOR_SCOPE_ID --state TOKEN. Promotion requires an Agent profile with explicit mayPromoteScope permission. Definition tree is referenced by instances; scope and availability are enforced by the mutation service. For availability reasons, obtain query context summary, then query context component-availability SCOPE_ID [MATCH] [--limit N] --state TOKEN; the result includes ruleID and blockingComponentID for unavailable definitions.",
        "validation": "hamii \(version)\nvalidate --project PATH --json returns diagnostics with rule, severity, entityID and message. query components CONSUMER_SCOPE_ID TERM automatically rebuilds a missing or stale derived index only from a verified coordinated Canonical generation. External edits, pending transitions, unverifiable Git state, and storage failures remain fail closed; use index rebuild explicitly after supported external edits. If canonical Git files are marked assume-unchanged or skip-worktree or use Git filters, clear those settings before rebuilding. migrate plan --json preflights a format without changing it. migrate resolution --json lists finite, source-bound choices for clean committed historical input; zero-choice items stay blocked. Save a typed manifest outside Canonical data, then migrate prepare --resolution PATH --json creates a reviewed candidate and reports exact losses. Safe automatic sources still use migrate prepare --json. After reviewing exact IDs and losses, migrate publish REVIEW_ID SOURCE_OID CANDIDATE_OID --json publishes only that candidate; migrate recover --json reconciles an interrupted publication.",
        "integration": "hamii \(version)\nintegration contract SCREEN_ID --json returns semantic inputs, events, token/asset references, native and accessibility intent. integration plan SCREEN_ID --integration-profile PATH --json reads an explicitly selected v1 Repository Profile. Exit 0 means resolved; exit 5/category contract returns integrationPlan, resolutionIssues and blockedOutputs for Needs Resolution. Do not guess mappings or edit canonical files directly. generate swiftui SCREEN_ID TARGET_ID --json is a separate deterministic path for the supported static subset and returns an error for unsupported semantics.",
        "assets": "hamii \(version)\nasset import SCOPE_ID NAME MEDIA_TYPE SOURCE_PATH --storage git --state TOKEN writes a SHA-256 addressed repository blob and Asset metadata. Large binary Git/LFS policy is unresolved; choose Git storage explicitly. layer image SCREEN_ID PARENT_ID ASSET_ID NAME --state TOKEN adds an image reference. Run validate --json to check blob integrity. Remote caches and thumbnails are not canonical data.",
        "preview": "hamii \(version)\npreview plan SURFACE_ID --json checks declared target capabilities and semantic support for one AppSurface. The current Native Preview capability catalog applies to macOS SwiftUI only; other target profiles fail closed even with Exact declarations because Native Preview coverage is not registered for them. This does not assert that their framework APIs are unsupported. A successful plan reports that the IR is supported; an installed and running Native Preview Host is a separate requirement. iOS Simulator and Android Hosts are not yet implemented.",
        "context": "hamii \(version)\nUse --json. Prefer query context session [--screen SCREEN_ID --layer LAYER_ID] for multiple reads. It emits an initial summary, then accepts one NDJSON request per line: layer {op,screenID,layerID}, resources {op,consumerScopeID,kind,matching?,limit?}, componentAvailability {op,consumerScopeID,matching?,limit?}, component {op,consumerScopeID,componentID}, token {op,consumerScopeID,tokenID}, surface {op,surfaceID}, or {op:close}. op is the operation name and all string values must be JSON quoted. Responses reuse the initial observation; requests never accept --state. Lines are limited to 64 KiB. usage and notFound errors have terminal:false; other errors have terminal:true and end the process. On a terminal error start a new session; never combine observations. EOF closes without a response. Mutations use existing one-shot commands with the initial observation.statePrecondition as --state TOKEN. For one-shot reads, start with query context summary [--screen SCREEN_ID --layer LAYER_ID]. Use its observation.statePrecondition as --state TOKEN for every follow-up: query context layer SCREEN_ID LAYER_ID; query context resources SCOPE_ID component|token|asset [MATCH] [--limit N]; query context component-availability SCOPE_ID [MATCH] [--limit N]; query context component SCOPE_ID COMPONENT_ID; query context token SCOPE_ID TOKEN_ID; query context surface SURFACE_ID. Surface detail includes bounded capability losses and Preview Plan diagnostics; it does not prove Native Preview Host availability. Resource results are Scope-filtered and bounded. Component availability is a separate bounded read including unavailable components and stable rule/blocker IDs; it does not change resources semantics. Never combine responses with different statePrecondition values. Request selected detail only when needed. Mutate through existing commands with the same --state TOKEN. On conflict, restart from summary. Do not edit Canonical files directly or use full inspect as the routine AI context."
    ]

    static func isContextSessionInvocation(_ raw: [String]) -> Bool {
        var args = raw.filter { $0 != "--json" }
        for name in ["--project", "--screen", "--layer", "--profile", "--state", "--limit"] {
            _ = takeOption(name, from: &args)
        }
        return Array(args.prefix(3)) == ["query", "context", "session"]
    }

    static func writeJSON(_ output: Output) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(output) + Data([0x0A]))
    }

    static func runContextSession(_ raw: [String]) throws -> Int32 {
        var args = raw
        func option(_ name: String) throws -> String? {
            guard let index = args.firstIndex(of: name) else { return nil }
            guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--"),
                  !args[index + 1].isEmpty else {
                throw CLIError(category: "usage", message: "Missing value for \(name)")
            }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            guard !args.contains(name) else { throw CLIError(category: "usage", message: "Duplicate \(name)") }
            return value
        }
        guard args.filter({ $0 == "--json" }).count == 1 else {
            throw CLIError(category: "usage", message: "Context session requires --json")
        }
        args.removeAll { $0 == "--json" }
        let project = try option("--project") ?? FileManager.default.currentDirectoryPath
        let screen = try option("--screen")
        let layer = try option("--layer")
        guard args == ["query", "context", "session"], layer == nil || screen != nil else {
            throw CLIError(category: "usage", message: "Context session accepts only --project, --json, --screen and --layer")
        }
        let selection = screen.map { ContextSelection(screenID: EntityID($0), layerID: layer.map(EntityID.init)) }
        let started = try ProjectContextReadSession.start(
            repository: CanonicalRepository(root: URL(fileURLWithPath: project, isDirectory: true)),
            selection: selection)
        try writeJSON(Output(ok: true, context: .summary(started.initialSummary)))
        let reader = ContextSessionLineReader(input: .standardInput)
        while let line = try reader.next() {
            do {
                guard case .bytes(let data) = line else {
                    throw ContextSessionInputError.usage("Request exceeds 64 KiB; line discarded")
                }
                let context: ContextCLIOutput
                switch try ContextSessionRequest.decode(data) {
                case .close:
                    try writeJSON(Output(ok: true, message: "Context session closed"))
                    return 0
                case .layer(let screen, let layer):
                    context = .layer(try started.session.layerDetail(screenID: screen, layerID: layer))
                case .resources(let scope, let kind, let matching, let limit):
                    context = .resources(try started.session.resources(consumerScopeID: scope, kind: kind,
                        matching: matching, limit: limit))
                case .componentAvailability(let scope, let matching, let limit):
                    context = .componentAvailability(try started.session.componentAvailability(
                        consumerScopeID: scope, matching: matching, limit: limit))
                case .component(let scope, let component):
                    context = .component(try started.session.componentDetail(componentID: component, consumerScopeID: scope))
                case .token(let scope, let token):
                    context = .token(try started.session.tokenDetail(tokenID: token, consumerScopeID: scope))
                case .surface(let surface):
                    context = .surface(try started.session.surfaceCapabilityDetail(surfaceID: surface))
                }
                try writeJSON(Output(ok: true, context: context))
            } catch {
                var (output, code) = failureOutput(error)
                let terminal = output.category != "usage" && output.category != "notFound"
                output.terminal = terminal
                try writeJSON(output)
                if terminal { return code }
            }
        }
        return 0
    }

    static func run(_ raw: [String]) throws -> Output {
        var args = raw.filter { $0 != "--json" }
        let project = takeOption("--project", from: &args) ?? FileManager.default.currentDirectoryPath
        let profileName = takeOption("--profile", from: &args) ?? "builder"
        let stateText = takeOption("--state", from: &args)
        let storage = takeOption("--storage", from: &args)
        let resolutionPath = takeOption("--resolution", from: &args)
        let limitText = takeOption("--limit", from: &args)
        let selectedScreenText = takeOption("--screen", from: &args)
        let selectedLayerText = takeOption("--layer", from: &args)
        guard args.filter({ $0 == "--integration-profile" }).count <= 1 else {
            throw CLIError(category: "usage", message: "Duplicate --integration-profile")
        }
        let integrationProfilePath = takeOption("--integration-profile", from: &args)
        guard let verb = args.first else { throw CLIError(category: "usage", message: usage) }
        guard integrationProfilePath == nil || (args.count == 3 && args[0] == "integration" && args[1] == "plan") else {
            throw CLIError(category: "usage", message: "--integration-profile is valid only for integration plan")
        }
        guard resolutionPath == nil || args == ["migrate", "prepare"] else {
            throw CLIError(category: "usage", message: "--resolution is valid only for migrate prepare")
        }
        let isContextQuery = args.count >= 2 && args[0] == "query" && args[1] == "context"
        guard isContextQuery || (limitText == nil && selectedScreenText == nil && selectedLayerText == nil) else {
            throw CLIError(category: "usage", message: "--limit, --screen and --layer are context query options")
        }
        let path = URL(fileURLWithPath: project, isDirectory: true)
        let repository = CanonicalRepository(root: path)
        let service = ProjectService(repository: repository)
        if verb == "skills" {
            guard args.count >= 2 else { throw CLIError(category: "usage", message: usage) }
            if args[1] == "list" { return Output(ok: true, skills: skillTexts.keys.sorted()) }
            if args[1] == "get", args.count == 3, let skill = skillTexts[args[2]] { return Output(ok: true, skill: skill) }
            throw CLIError(category: "usage", message: "Unknown skill or skills command")
        }
        if verb == "version" { return Output(ok: true, message: version) }
        if args == ["migrate", "plan"] {
            let plan = try MigrationPreflight.plan(repository: path)
            return Output(ok: plan.blockers.isEmpty, category: plan.blockers.isEmpty ? nil : "migrationRequired", migration: plan)
        }
        if args == ["migrate", "resolution"] {
            guard resolutionPath == nil else { throw CLIError(category: "usage", message: usage) }
            return Output(ok: true, migrationResolution:
                try MigrationCandidatePreparer().resolutionReport(repository: path))
        }
        if args == ["migrate", "prepare"] {
            let resolution = try resolutionPath.map { value in
                let bytes: Data
                do { bytes = try Data(contentsOf: URL(fileURLWithPath: value)) }
                catch { throw CLIError(category: "migration", message: "Cannot read migration resolution manifest") }
                return try MigrationResolutionManifest.decodeStrict(bytes)
            }
            return Output(ok: true, migrationReview:
                try MigrationCandidatePreparer().prepare(repository: path, resolution: resolution))
        }
        if args.count == 5 && args[0] == "migrate" && args[1] == "publish" {
            return Output(ok: true, migrationPublication: try MigrationPublisher(root: path, index: PublishedCanonicalIndex())
                .publish(reviewID: args[2], confirmedSourceOID: args[3], confirmedCandidateOID: args[4]))
        }
        if args == ["migrate", "recover"] {
            return Output(ok: true, migrationPublication: try MigrationPublisher(root: path, index: PublishedCanonicalIndex()).recover())
        }
        if verb == "init" {
            guard args.count == 2 else { throw CLIError(category: "usage", message: "init NAME") }
            guard !FileManager.default.fileExists(atPath: path.appendingPathComponent("hamii.json").path) else {
                throw CanonicalError.alreadyExists
            }
            try initializeGit(at: path)
            let document = try repository.create(name: args[1])
            return Output(ok: true, document: document, statePrecondition: try repository.observe().statePrecondition)
        }
        if verb == "inspect" {
            let observed = try service.observe()
            return Output(ok: true, document: observed.document, statePrecondition: observed.statePrecondition)
        }
        if isContextQuery {
            let context = ProjectContextService(repository: repository)
            if args == ["query", "context", "summary"] {
                guard limitText == nil, selectedLayerText == nil || selectedScreenText != nil else {
                    throw CLIError(category: "usage", message: "Summary requires --screen with --layer and does not accept --limit")
                }
                let selection = selectedScreenText.map {
                    ContextSelection(screenID: EntityID($0), layerID: selectedLayerText.map(EntityID.init))
                }
                return Output(ok: true, context: .summary(try context.projectSummary(
                    selection: selection, expectedState: stateText.map(ClientPrecondition.init))))
            }
            guard selectedScreenText == nil, selectedLayerText == nil,
                  let stateText, !stateText.isEmpty else {
                throw CLIError(category: "usage", message: "Context detail queries require --state TOKEN from summary")
            }
            let expected = ClientPrecondition(stateText)
            if args.count == 5 && args[2] == "layer" {
                guard limitText == nil else { throw CLIError(category: "usage", message: "--limit applies only to resources") }
                return Output(ok: true, context: .layer(try context.layerDetail(
                    screenID: EntityID(args[3]), layerID: EntityID(args[4]), expectedState: expected)))
            }
            if (args.count == 5 || args.count == 6) && args[2] == "resources" {
                guard let kind = ContextResourceKind(rawValue: args[4]),
                      let limit = limitText == nil ? 32 : Int(limitText!), (1...100).contains(limit) else {
                    throw CLIError(category: "usage", message: "Resources require component|token|asset and --limit 1...100")
                }
                return Output(ok: true, context: .resources(try context.resources(
                    consumerScopeID: EntityID(args[3]), kind: kind,
                    matching: args.count == 6 ? args[5] : nil, limit: limit, expectedState: expected)))
            }
            if (args.count == 4 || args.count == 5) && args[2] == "component-availability" {
                guard let limit = limitText == nil ? 32 : Int(limitText!), (1...100).contains(limit) else {
                    throw CLIError(category: "usage", message: "Component availability requires --limit 1...100")
                }
                return Output(ok: true, context: .componentAvailability(try context.componentAvailability(
                    consumerScopeID: EntityID(args[3]), matching: args.count == 5 ? args[4] : nil,
                    limit: limit, expectedState: expected)))
            }
            guard limitText == nil else { throw CLIError(category: "usage", message: "--limit applies only to context lists") }
            if args.count == 5 && args[2] == "component" {
                return Output(ok: true, context: .component(try context.componentDetail(
                    componentID: EntityID(args[4]), consumerScopeID: EntityID(args[3]), expectedState: expected)))
            }
            if args.count == 5 && args[2] == "token" {
                return Output(ok: true, context: .token(try context.tokenDetail(
                    tokenID: EntityID(args[4]), consumerScopeID: EntityID(args[3]), expectedState: expected)))
            }
            if args.count == 4 && args[2] == "surface" {
                return Output(ok: true, context: .surface(try context.surfaceCapabilityDetail(
                    surfaceID: EntityID(args[3]), expectedState: expected)))
            }
            throw CLIError(category: "usage", message: "Unknown query context command")
        }
        if args == ["git", "recover"] {
            guard !WorktreeCoordinator(root: path).migrationPublicationPending() else {
                throw CLIError(category: "transitionPending", message: "Migration publication is pending; run hamii migrate recover")
            }
            let publisher = ValidatedMergePublisher(root: path, index: PublishedCanonicalIndex())
            let observed = try publisher.hasPendingPublication ? publisher.recover() : ManagedGit(root: path).recover()
            return Output(ok: true, document: observed.document, statePrecondition: observed.statePrecondition)
        }
        if args.count == 3 && args[0] == "git" && args[1] == "switch" {
            guard let stateText, !stateText.isEmpty else {
                throw CLIError(category: "usage", message: "Managed git switch requires --state TOKEN from inspect")
            }
            let observed = try ManagedGit(root: path).switchBranch(args[2], expectedState: ClientPrecondition(stateText))
            return Output(ok: true, document: observed.document, statePrecondition: observed.statePrecondition)
        }
        if args.count == 4 && args[0] == "git" && args[1] == "merge" && args[2] == "check" {
            guard let stateText, !stateText.isEmpty else {
                throw CLIError(category: "usage", message: "Merge candidate check requires --state TOKEN from inspect")
            }
            return try ManagedGit(root: path).withMergeCandidate(args[3], expectedState: ClientPrecondition(stateText)) { candidate in
                try CanonicalRepository(root: candidate.root).withCoordinatedSnapshot { snapshot in
                    let calculator = GitCanonicalRevisionCalculator()
                    let source = try calculator.current(at: candidate.root)
                    let index = try LocalIndex(projectRoot: candidate.root, documentID: snapshot.document.id,
                                               revisionCalculator: calculator,
                                               storageRoot: candidate.root.deletingLastPathComponent().appendingPathComponent("indexes"))
                    _ = try index.rebuild(from: snapshot, canonicalRevision: source)
                    guard try calculator.current(at: candidate.root) == source else { throw IndexError.stale }
                    return Output(ok: true, mergeCheck: MergeCheck(sourceHead: candidate.sourceHead,
                        candidateHead: candidate.candidateHead, documentID: snapshot.document.id,
                        documentRevision: snapshot.document.revision, indexedCandidate: true, published: false))
                }
            }
        }
        if args.count == 4 && args[0] == "git" && args[1] == "merge" && args[2] == "publish" {
            guard let stateText, !stateText.isEmpty else {
                throw CLIError(category: "usage", message: "Merge publication requires --state TOKEN from inspect")
            }
            let observed = try ValidatedMergePublisher(root: path, index: PublishedCanonicalIndex())
                .publish(args[3], expectedState: ClientPrecondition(stateText))
            return Output(ok: true, message: "Published validated merge candidate", document: observed.document,
                          statePrecondition: observed.statePrecondition)
        }
        if verb == "validate" {
            var diagnostics = try repository.diagnostics()
            do { _ = try AgentProfilesRepository(root: path).profiles() }
            catch { diagnostics.append(Diagnostic("agent.profile", String(describing: error))) }
            let valid = !diagnostics.contains(where: { $0.severity == .error })
            return Output(ok: valid, category: valid ? nil : "validation", diagnostics: diagnostics)
        }
        if args == ["index", "rebuild"] {
            return try repository.withCoordinatedSnapshot { snapshot in
                let calculator = GitCanonicalRevisionCalculator()
                let before = try calculator.current(at: path)
                let stable = try calculator.current(at: path)
                guard before == stable else { throw IndexError.stale }
                // An external edit can be indexed by the existing slow oracle,
                // but it cannot inherit a coordinated-generation proof.
                let sourceBinding: IndexSourceGenerationBinding
                do {
                    sourceBinding = .bound(try CanonicalGenerationStore(root: path).requireMatchingStable(snapshot).generation)
                } catch CanonicalGenerationError.unknownState {
                    sourceBinding = .explicitlyUnbound
                }
                _ = try LocalIndex(projectRoot: path, documentID: snapshot.document.id, revisionCalculator: calculator)
                    .rebuild(from: snapshot, canonicalRevision: stable, sourceGenerationBinding: sourceBinding)
                guard try calculator.current(at: path) == stable else { throw IndexError.stale }
                return Output(ok: true, message: "Indexed revision \(snapshot.document.revision)")
            }
        }
        if args.count == 4 && args[0] == "query" && args[1] == "components" {
            do {
                let hits = try IndexQuerySession(projectRoot: path)
                    .components(matching: args[3], consumerScopeID: EntityID(args[2]))
                return Output(ok: true, hits: hits)
            } catch let error as IndexError {
                throw error
            } catch CanonicalError.managedGitPending {
                throw CanonicalError.managedGitPending
            } catch CanonicalError.transactionCorrupt(let reason) {
                throw CanonicalError.transactionCorrupt(reason)
            } catch {
                // A malformed or disappearing canonical shard cannot establish
                // a source snapshot for the published index.
                throw IndexError.stale
            }
        }
        if args.count == 4 && args[0] == "generate" && args[1] == "swiftui" {
            return Output(ok: true, generated: try SwiftUIGenerator.generate(document: service.document(), screenID: EntityID(args[2]), targetID: EntityID(args[3])))
        }
        if args.count == 3 && args[0] == "integration" && args[1] == "contract" {
            return Output(ok: true, contract: try IntegrationContracts.make(screenID: EntityID(args[2]), document: service.document()))
        }
        if args.count == 3 && args[0] == "integration" && args[1] == "plan" {
            guard let integrationProfilePath, !integrationProfilePath.isEmpty,
                  !integrationProfilePath.hasPrefix("--") else {
                throw CLIError(category: "usage", message: "integration plan requires --integration-profile PATH")
            }
            let document = try service.document()
            try IntegrationProfileFile.requireDocumentVersion(document.versions.integrationProfile)
            let contract = try IntegrationContracts.make(screenID: EntityID(args[2]), document: document)
            let profile = try IntegrationProfileFile.load(at: URL(fileURLWithPath: integrationProfilePath))
            let plan = IntegrationContracts.plan(contract, profile: profile)
            return Output(ok: !plan.needsResolution, category: plan.needsResolution ? "contract" : nil,
                          integrationPlan: plan, resolutionIssues: plan.resolutionIssues,
                          blockedOutputs: plan.blockedOutputs)
        }
        if args.count == 3 && args[0] == "preview" && args[1] == "plan" {
            let document = try service.document()
            guard let surface = document.pages.flatMap(\.surfaces).first(where: { $0.id == EntityID(args[2]) }) else {
                throw CLIError(category: "notFound", message: "AppSurface not found: \(args[2])")
            }
            let plan = TargetPlanner.plan(surface: surface, document: document)
            return Output(ok: plan.canPreview, category: plan.canPreview ? nil : "unsupportedCapability", previewPlan: plan)
        }
        if verb == "component", args.count == 3, args[1] == "list" {
            return Output(ok: true, components: try service.availableComponents(for: EntityID(args[2])))
        }
        guard let stateText, !stateText.isEmpty else {
            throw CLIError(category: "usage", message: "Mutation requires --state TOKEN from inspect")
        }
        let expectedState = ClientPrecondition(stateText)
        let profile = try AgentProfilesRepository(root: path).profile(named: profileName)
        if args.count == 6 && args[0] == "asset" && args[1] == "import" {
            guard storage == "git" else { throw CLIError(category: "usage", message: "Asset import requires explicit --storage git") }
            let data = try Data(contentsOf: URL(fileURLWithPath: args[5]))
            let result = try service.importRepositoryAsset(data, name: args[3], scopeID: EntityID(args[2]), mediaType: args[4], expectedState: expectedState, author: .agent, agent: profile, blobs: CanonicalBlobStore(root: path))
            return Output(ok: true, mutation: result)
        }
        let intent: AuthoringIntent
        if args.count == 3 && args[0] == "page" && args[1] == "create" {
            intent = .createPage(name: args[2])
        } else if args.count == 4 && args[0] == "scope" && args[1] == "create" {
            intent = .createScope(name: args[3], parentID: EntityID(args[2]))
        } else if args.count == 4 && args[0] == "screen" && args[1] == "create" {
            intent = .createScreen(name: args[3], scopeID: EntityID(args[2]))
        } else if args.count == 4 && args[0] == "target" && args[1] == "add" {
            guard let platform = Platform(rawValue: args[2]), let framework = Framework(rawValue: args[3]) else {
                throw CLIError(category: "usage", message: "Unknown platform or framework")
            }
            intent = .addTarget(platform: platform, framework: framework)
        } else if args.count == 8 && args[0] == "surface" && args[1] == "add" {
            intent = .addSurface(pageID: EntityID(args[2]), screenID: EntityID(args[3]), targetID: EntityID(args[4]), device: args[5], runtime: args[6], buildEnvironment: args[7])
        } else if args.count == 4 && args[0] == "surface" && args[1] == "target" {
            intent = .setSurfaceTarget(surfaceID: EntityID(args[2]), targetID: EntityID(args[3]))
        } else if args.count == 5 && args[0] == "capability" && args[1] == "set" {
            guard let support = CapabilitySupport(rawValue: args[4]) else { throw CLIError(category: "usage", message: "Unknown capability support state") }
            intent = .declareCapability(targetID: EntityID(args[2]), key: CapabilityKey(args[3]), support: support)
        } else if args.count == 7 && args[0] == "layer" && args[1] == "add" {
            guard let kind = LayerKind(rawValue: args[4]) else { throw CLIError(category: "usage", message: "Unknown layer kind \(args[4])") }
            intent = .addLayer(screenID: EntityID(args[2]), parentID: EntityID(args[3]), kind: kind, name: args[5], text: args[6] == "-" ? nil : args[6])
        } else if args.count == 5 && args[0] == "layer" && args[1] == "text" {
            intent = .setText(screenID: EntityID(args[2]), layerID: EntityID(args[3]), text: args[4])
        } else if args.count == 6 && args[0] == "layer" && args[1] == "token" {
            guard let property = LayoutTokenProperty(rawValue: args[4]) else { throw CLIError(category: "usage", message: "Layout token property must be spacing or padding") }
            intent = .setLayoutToken(screenID: EntityID(args[2]), layerID: EntityID(args[3]), property: property, tokenID: args[5] == "-" ? nil : EntityID(args[5]))
        } else if args.count == 6 && args[0] == "token" && (args[1] == "create" || args[1] == "alias") {
            guard let kind = TokenKind(rawValue: args[4]) else { throw CLIError(category: "usage", message: "Unknown token kind \(args[4])") }
            let value: TokenValue = args[1] == "alias" ? .reference(EntityID(args[5])) : .literal(args[5])
            intent = .createToken(name: args[3], kind: kind, scopeID: EntityID(args[2]), value: value)
        } else if args.count == 6 && args[0] == "layer" && args[1] == "image" {
            intent = .addImageLayer(screenID: EntityID(args[2]), parentID: EntityID(args[3]), assetID: EntityID(args[4]), name: args[5])
        } else if args.count == 4 && args[0] == "component" && args[1] == "create" {
            intent = .createComponent(name: args[3], scopeID: EntityID(args[2]))
        } else if args.count == 5 && args[0] == "component" && args[1] == "instantiate" {
            intent = .instantiate(screenID: EntityID(args[2]), parentID: EntityID(args[3]), definitionID: EntityID(args[4]))
        } else if args.count == 4 && args[0] == "component" && args[1] == "promote" {
            intent = .promoteComponent(definitionID: EntityID(args[2]), newOwnerID: EntityID(args[3]))
        } else { throw CLIError(category: "usage", message: usage) }
        let result = try service.mutate(intent, expectedState: expectedState, author: .agent, agent: profile)
        return Output(ok: true, mutation: result)
    }

    static let usage = "hamii [--project PATH] [--profile NAME] [--json] <version|init NAME|inspect|validate|git switch BRANCH|git recover|git merge check BRANCH|git merge publish BRANCH|preview plan SURFACE_ID|migrate plan|migrate resolution|migrate prepare [--resolution PATH]|migrate publish REVIEW_ID SOURCE_OID CANDIDATE_OID|migrate recover|skills list|get NAME|index rebuild|query components SCOPE_ID TERM|query context session [--screen ID --layer ID]|query context summary [--screen ID --layer ID]|query context layer SCREEN_ID LAYER_ID --state TOKEN|query context resources SCOPE_ID component|token|asset [MATCH] [--limit N] --state TOKEN|query context component-availability SCOPE_ID [MATCH] [--limit N] --state TOKEN|query context component SCOPE_ID COMPONENT_ID --state TOKEN|query context token SCOPE_ID TOKEN_ID --state TOKEN|query context surface SURFACE_ID --state TOKEN|generate swiftui SCREEN_ID TARGET_ID|integration contract SCREEN_ID|integration plan SCREEN_ID --integration-profile PATH|page create NAME|scope create PARENT_ID NAME|screen create SCOPE_ID NAME|target add PLATFORM FRAMEWORK|surface add PAGE_ID SCREEN_ID TARGET_ID DEVICE RUNTIME BUILD_ENVIRONMENT|surface target SURFACE_ID TARGET_ID|capability set TARGET_ID KEY SUPPORT|asset import SCOPE_ID NAME MEDIA_TYPE SOURCE_PATH --storage git|layer add SCREEN_ID PARENT_ID KIND NAME TEXT|layer text SCREEN_ID LAYER_ID TEXT|layer token SCREEN_ID LAYER_ID spacing|padding TOKEN_ID|-|token create SCOPE_ID NAME KIND VALUE|token alias SCOPE_ID NAME KIND TOKEN_ID|layer image SCREEN_ID PARENT_ID ASSET_ID NAME|component create SCOPE_ID NAME|component list SCOPE_ID|component instantiate SCREEN_ID PARENT_ID DEFINITION_ID|component promote DEFINITION_ID ANCESTOR_SCOPE_ID> [--state TOKEN]"

    static func takeOption(_ name: String, from args: inout [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    static func initializeGit(at path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path.path, "init", "--quiet"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { throw CLIError(category: "storage", message: "Could not initialize Git repository") }
        }
        let ignore = path.appendingPathComponent(".gitignore")
        var contents = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
        if !contents.split(whereSeparator: \.isNewline).contains(Substring(".hamii/")) {
            if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
            contents += ".hamii/\n"
            try contents.write(to: ignore, atomically: true, encoding: .utf8)
        }
    }
}

private func failureOutput(_ error: Error, terminal: Bool? = nil) -> (Output, Int32) {
    let category: String
    let code: Int32
    switch error {
    case is ContextSessionInputError: category = "usage"; code = 2
    case ProjectContextSessionError.invalidated: category = "conflict"; code = 3
    case let value as CLIError: category = value.category; code = value.category == "transitionPending" ? 7 : 2
    case AuthoringError.staleRevision, AuthoringError.staleState: category = "conflict"; code = 3
    case AuthoringError.approvalRequired: category = "approval"; code = 4
    case AuthoringError.mutationLimit: category = "permission"; code = 4
    case AuthoringError.notFound: category = "notFound"; code = 2
    case AuthoringError.validation: category = "validation"; code = 5
    case ContextQueryError.invalidLimit: category = "usage"; code = 2
    case let value as CanonicalError:
        if case .unsupportedFormat = value { category = "migrationRequired"; code = 6 }
        else if case .transactionConflict = value { category = "conflict"; code = 3 }
        else if case .managedGitPending = value { category = "transitionPending"; code = 7 }
        else { category = "storage"; code = 7 }
    case ManagedGitError.dirtyWorktree, ManagedGitError.changedDuringTransition: category = "conflict"; code = 3
    case is ManagedGitError: category = "git"; code = 7
    case is MergePublicationError: category = "transitionPending"; code = 7
    case let value as MigrationPublicationError:
        switch value {
        case .sourceChanged: category = "conflict"; code = 3
        case .unknownSourceState: category = "transitionPending"; code = 7
        default: category = "migration"; code = 6
        }
    case is CanonicalGenerationError: category = "transitionPending"; code = 7
    case IndexError.stale: category = "staleIndex"; code = 8
    case IndexError.unverifiableSource: category = "staleIndex"; code = 8
    case is IndexError: category = "index"; code = 7
    case is GenerationError: category = "unsupportedCapability"; code = 9
    case is ContractError: category = "contract"; code = 5
    case let value as IntegrationProfileFileError:
        switch value {
        case .unsupportedVersion: category = "migrationRequired"; code = 6
        case .unreadable: category = "storage"; code = 7
        case .invalid: category = "contract"; code = 5
        }
    case is MigrationPreflightError: category = "migration"; code = 6
    case let value as MigrationPreparationError:
        switch value {
        case .dirtySource, .staleSource: category = "conflict"; code = 3
        case .alreadyCurrent: category = "alreadyCurrent"; code = 6
        default: category = "migration"; code = 6
        }
    case is MigrationEdgeFailure: category = "migration"; code = 6
    case let value as MigrationResolutionFailure:
        if case .staleSource = value { category = "conflict"; code = 3 }
        else { category = "migration"; code = 6 }
    case is AgentProfileError: category = "profile"; code = 4
    case is BlobError: category = "assetIntegrity"; code = 5
    default: category = "internal"; code = 1
    }
    let blockers: [String]?
    if case MigrationPreparationError.migrationUnavailable(let reasons) = error { blockers = reasons }
    else { blockers = nil }
    return (Output(ok: false, category: category, message: String(describing: error), blockers: blockers, terminal: terminal), code)

}

let json = CommandLine.arguments.contains("--json")
let isSession = CLI.isContextSessionInvocation(Array(CommandLine.arguments.dropFirst()))
do {
    if isSession { exit(try CLI.runContextSession(Array(CommandLine.arguments.dropFirst()))) }
    let output = try CLI.run(Array(CommandLine.arguments.dropFirst()))
    if json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        FileHandle.standardOutput.write(data + Data([0x0A]))
    } else if let skill = output.skill {
        print(skill)
    } else if let skills = output.skills {
        print(skills.joined(separator: "\n"))
    } else if let message = output.message {
        print(message)
    } else if let context = output.context {
        print(context.description)
    } else if let mutation = output.mutation {
        print("revision \(mutation.revision): \(mutation.patches.map(\.path).joined(separator: ", "))")
    } else if let document = output.document {
        print("\(document.name) (revision \(document.revision))")
    } else if let components = output.components {
        print(components.map { "\($0.id.rawValue) \($0.name)" }.joined(separator: "\n"))
    } else if let hits = output.hits {
        print(hits.map { "\($0.id.rawValue) \($0.name) (\($0.usageCount) uses)" }.joined(separator: "\n"))
    } else if let generated = output.generated {
        print(generated.source)
    } else if let contract = output.contract {
        print("\(contract.name): \(contract.inputs.count) inputs, \(contract.events.count) events")
    } else if let plan = output.integrationPlan {
        print(plan.needsResolution ? "Integration plan needs resolution: \(plan.resolutionIssues.count) issues" : "Integration plan resolved")
    } else if let migration = output.migration {
        print("Document format \(migration.sourceDocumentFormatVersion): \(migration.state)")
    } else if let review = output.migrationReview {
        print("Validated migration candidate \(review.sourceOID) → \(review.candidateOID); source branch unchanged")
    } else if let plan = output.previewPlan {
        print(plan.canPreview ? "Preview plan supported" : plan.diagnostics.map { "\($0.rule): \($0.message)" }.joined(separator: "\n"))
    } else if let check = output.mergeCheck {
        print("Validated merge candidate \(check.candidateHead); project unchanged")
    } else if let diagnostics = output.diagnostics {
        print(diagnostics.isEmpty ? "valid" : diagnostics.map { "\($0.rule): \($0.message)" }.joined(separator: "\n"))
    }
    if !output.ok { exit(output.category == "migrationRequired" ? 6 : 5) }
} catch {
    let (output, code) = failureOutput(error, terminal: isSession ? true : nil)
    let category = output.category!
    if json, let data = try? JSONEncoder().encode(output) { FileHandle.standardOutput.write(data + Data([0x0A])) }
    else { FileHandle.standardError.write(Data("\(category): \(error)\n".utf8)) }
    exit(code)
}
