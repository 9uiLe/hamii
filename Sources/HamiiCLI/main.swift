import Darwin
import Foundation
import HamiiCore
import HamiiApplication
import HamiiFormat
import HamiiIndex
import HamiiGeneration
import HamiiIntegration
import HamiiMigrations

private struct CLIError: Error, CustomStringConvertible {
    var category: String
    var message: String
    var description: String { message }
}

private struct Output: Encodable {
    var ok: Bool
    var category: String?
    var message: String?
    var document: Document?
    var mutation: MutationResult?
    var components: [ComponentDefinition]?
    var skills: [String]?
    var skill: String?
    var diagnostics: [Diagnostic]?
    var hits: [ComponentHit]?
    var generated: GeneratedSource?
    var contract: IntegrationContract?
    var migration: MigrationPlan?
    var previewPlan: TargetPlan?
    init(ok: Bool, category: String? = nil, message: String? = nil, document: Document? = nil, mutation: MutationResult? = nil, components: [ComponentDefinition]? = nil, skills: [String]? = nil, skill: String? = nil, diagnostics: [Diagnostic]? = nil, hits: [ComponentHit]? = nil, generated: GeneratedSource? = nil, contract: IntegrationContract? = nil, migration: MigrationPlan? = nil, previewPlan: TargetPlan? = nil) {
        self.ok = ok; self.category = category; self.message = message; self.document = document
        self.mutation = mutation; self.components = components; self.skills = skills
        self.skill = skill; self.diagnostics = diagnostics; self.hits = hits
        self.generated = generated; self.contract = contract; self.migration = migration
        self.previewPlan = previewPlan
    }
}

private enum CLI {
    static let version = "0.1.0"
    static let skillTexts: [String: String] = [
        "bootstrap": "hamii \(version)\nUse hamii skills list and hamii skills get NAME. Load only the relevant live skill. Global options: --project PATH --json. Create a Git-backed project with hamii init NAME --project PATH --json; inspect it with hamii inspect --project PATH --json. Do not guess commands or edit canonical files directly. Supply --revision for every mutation.",
        "authoring": "hamii \(version)\nGlobal options: --project PATH --profile NAME --json. Inspect: hamii inspect. Mutations require --revision N from inspect. Commands: page create NAME; scope create PARENT_ID NAME; screen create SCOPE_ID NAME; target add PLATFORM FRAMEWORK; surface add PAGE_ID SCREEN_ID TARGET_ID DEVICE RUNTIME BUILD_ENVIRONMENT; surface target SURFACE_ID TARGET_ID; capability set TARGET_ID KEY SUPPORT; layer add SCREEN_ID PARENT_ID KIND NAME TEXT; layer text SCREEN_ID LAYER_ID TEXT. Use - for no text. Read the tokens, components or assets skill when needed. All mutations use the same Authoring Harness validation as GUI.",
        "tokens": "hamii \(version)\ntoken create OWNER_SCOPE_ID NAME KIND LITERAL --revision N creates a primitive token; token alias OWNER_SCOPE_ID NAME KIND TARGET_TOKEN_ID --revision N creates a semantic alias. KIND is color|typography|spacing|radius|border|shadow|opacity|motion. Spacing literals are nonnegative finite numbers. layer token SCREEN_ID LAYER_ID spacing|padding TOKEN_ID|- --revision N sets or clears a layout token. ArchitectureScope ownership and token references are validated before save.",
        "components": "hamii \(version)\ncomponent list CONSUMER_SCOPE_ID; component create OWNER_SCOPE_ID NAME --revision N; component instantiate SCREEN_ID PARENT_LAYER_ID DEFINITION_ID --revision N; component promote DEFINITION_ID ANCESTOR_SCOPE_ID --revision N. Promotion requires an Agent profile with explicit mayPromoteScope permission. Definition tree is referenced by instances; scope and availability are enforced by the mutation service.",
        "validation": "hamii \(version)\nvalidate --project PATH --json returns diagnostics with rule, severity, entityID and message. index rebuild recreates .hamii/index.sqlite from canonical files. query components CONSUMER_SCOPE_ID TERM uses the index and rejects stale source fingerprints or revisions with staleIndex; run index rebuild after external edits. migrate plan --json preflights a format without changing it. Unsupported persisted formats require an isolated migration edge.",
        "integration": "hamii \(version)\nintegration contract SCREEN_ID --json returns semantic inputs, events, token/asset references, native and accessibility intent. Unknown product mappings require review. generate swiftui SCREEN_ID TARGET_ID --json is a separate deterministic path for the supported static subset and returns an error for unsupported semantics.",
        "assets": "hamii \(version)\nasset import SCOPE_ID NAME MEDIA_TYPE SOURCE_PATH --storage git --revision N writes a SHA-256 addressed repository blob and Asset metadata. Large binary Git/LFS policy is unresolved; choose Git storage explicitly. layer image SCREEN_ID PARENT_ID ASSET_ID NAME --revision N adds an image reference. Run validate --json to check blob integrity. Remote caches and thumbnails are not canonical data.",
        "preview": "hamii \(version)\npreview plan SURFACE_ID --json checks declared target capabilities and semantic support for one AppSurface. A successful plan reports that the IR is supported; an installed and running Native Preview Host is a separate requirement. macOS SwiftUI supports the current in-process subset. iOS Simulator and Android Hosts are not yet implemented."
    ]

    static func run(_ raw: [String]) throws -> Output {
        var args = raw.filter { $0 != "--json" }
        let project = takeOption("--project", from: &args) ?? FileManager.default.currentDirectoryPath
        let profileName = takeOption("--profile", from: &args) ?? "builder"
        let revisionText = takeOption("--revision", from: &args)
        let storage = takeOption("--storage", from: &args)
        guard let verb = args.first else { throw CLIError(category: "usage", message: usage) }
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
        if verb == "init" {
            guard args.count == 2 else { throw CLIError(category: "usage", message: "init NAME") }
            try initializeGit(at: path)
            let document = try repository.create(name: args[1])
            return Output(ok: true, document: document)
        }
        if verb == "inspect" { return Output(ok: true, document: try service.document()) }
        if verb == "validate" {
            var diagnostics = try repository.diagnostics()
            do { _ = try AgentProfilesRepository(root: path).profiles() }
            catch { diagnostics.append(Diagnostic("agent.profile", String(describing: error))) }
            let valid = !diagnostics.contains(where: { $0.severity == .error })
            return Output(ok: valid, category: valid ? nil : "validation", diagnostics: diagnostics)
        }
        if args == ["index", "rebuild"] {
            let before = try CanonicalSourceFingerprint.current(at: path)
            let document = try service.document()
            let stable = try CanonicalSourceFingerprint.current(at: path)
            guard before == stable else { throw IndexError.stale }
            try LocalIndex(projectRoot: path).rebuild(from: document, sourceFingerprint: stable)
            guard try CanonicalSourceFingerprint.current(at: path) == stable else { throw IndexError.stale }
            return Output(ok: true, message: "Indexed revision \(document.revision)")
        }
        if args.count == 4 && args[0] == "query" && args[1] == "components" {
            let (id, revision) = try repository.identityAndRevision()
            let hits = try LocalIndex(projectRoot: path).components(matching: args[3], consumerScopeID: EntityID(args[2]), documentID: id, revision: revision)
            return Output(ok: true, hits: hits)
        }
        if args.count == 4 && args[0] == "generate" && args[1] == "swiftui" {
            return Output(ok: true, generated: try SwiftUIGenerator.generate(document: service.document(), screenID: EntityID(args[2]), targetID: EntityID(args[3])))
        }
        if args.count == 3 && args[0] == "integration" && args[1] == "contract" {
            return Output(ok: true, contract: try IntegrationContracts.make(screenID: EntityID(args[2]), document: service.document()))
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
        guard let revisionText, let revision = Int(revisionText) else {
            throw CLIError(category: "usage", message: "Mutation requires --revision N")
        }
        let profile = try AgentProfilesRepository(root: path).profile(named: profileName)
        if args.count == 6 && args[0] == "asset" && args[1] == "import" {
            guard storage == "git" else { throw CLIError(category: "usage", message: "Asset import requires explicit --storage git") }
            let data = try Data(contentsOf: URL(fileURLWithPath: args[5]))
            let result = try service.importRepositoryAsset(data, name: args[3], scopeID: EntityID(args[2]), mediaType: args[4], expectedRevision: revision, author: .agent, agent: profile, blobs: CanonicalBlobStore(root: path))
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
        let result = try service.mutate(intent, expectedRevision: revision, author: .agent, agent: profile)
        return Output(ok: true, mutation: result)
    }

    static let usage = "hamii [--project PATH] [--profile NAME] [--json] <version|init NAME|inspect|validate|preview plan SURFACE_ID|migrate plan|skills list|get NAME|index rebuild|query components SCOPE_ID TERM|generate swiftui SCREEN_ID TARGET_ID|integration contract SCREEN_ID|page create NAME|scope create PARENT_ID NAME|screen create SCOPE_ID NAME|target add PLATFORM FRAMEWORK|surface add PAGE_ID SCREEN_ID TARGET_ID DEVICE RUNTIME BUILD_ENVIRONMENT|surface target SURFACE_ID TARGET_ID|capability set TARGET_ID KEY SUPPORT|asset import SCOPE_ID NAME MEDIA_TYPE SOURCE_PATH --storage git|layer add SCREEN_ID PARENT_ID KIND NAME TEXT|layer text SCREEN_ID LAYER_ID TEXT|layer token SCREEN_ID LAYER_ID spacing|padding TOKEN_ID|-|token create SCOPE_ID NAME KIND VALUE|token alias SCOPE_ID NAME KIND TOKEN_ID|layer image SCREEN_ID PARENT_ID ASSET_ID NAME|component create SCOPE_ID NAME|component list SCOPE_ID|component instantiate SCREEN_ID PARENT_ID DEFINITION_ID|component promote DEFINITION_ID ANCESTOR_SCOPE_ID> [--revision N]"

    static func takeOption(_ name: String, from args: inout [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    static func initializeGit(at path: URL) throws {
        if FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path) { return }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path.path, "init", "--quiet"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw CLIError(category: "storage", message: "Could not initialize Git repository") }
    }
}

let json = CommandLine.arguments.contains("--json")
do {
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
    } else if let migration = output.migration {
        print("Document format \(migration.sourceDocumentFormatVersion): \(migration.state)")
    } else if let plan = output.previewPlan {
        print(plan.canPreview ? "Preview plan supported" : plan.diagnostics.map { "\($0.rule): \($0.message)" }.joined(separator: "\n"))
    } else if let diagnostics = output.diagnostics {
        print(diagnostics.isEmpty ? "valid" : diagnostics.map { "\($0.rule): \($0.message)" }.joined(separator: "\n"))
    }
    if !output.ok { exit(output.category == "migrationRequired" ? 6 : 5) }
} catch {
    let category: String
    let code: Int32
    switch error {
    case let value as CLIError: category = value.category; code = 2
    case AuthoringError.staleRevision: category = "conflict"; code = 3
    case AuthoringError.approvalRequired: category = "approval"; code = 4
    case AuthoringError.mutationLimit: category = "permission"; code = 4
    case AuthoringError.notFound: category = "notFound"; code = 2
    case AuthoringError.validation: category = "validation"; code = 5
    case let value as CanonicalError:
        if case .unsupportedFormat = value { category = "migrationRequired"; code = 6 }
        else if case .transactionConflict = value { category = "conflict"; code = 3 }
        else { category = "storage"; code = 7 }
    case IndexError.stale: category = "staleIndex"; code = 8
    case is IndexError: category = "index"; code = 7
    case is GenerationError: category = "unsupportedCapability"; code = 9
    case is ContractError: category = "contract"; code = 5
    case is MigrationPreflightError: category = "migration"; code = 6
    case is AgentProfileError: category = "profile"; code = 4
    case is BlobError: category = "assetIntegrity"; code = 5
    default: category = "internal"; code = 1
    }
    let output = Output(ok: false, category: category, message: String(describing: error))
    if json, let data = try? JSONEncoder().encode(output) { FileHandle.standardOutput.write(data + Data([0x0A])) }
    else { FileHandle.standardError.write(Data("\(category): \(error)\n".utf8)) }
    exit(code)
}
