import Foundation
import HamiiCore

public enum IntegrationMappingKind: String, Codable, Hashable, Sendable {
    case input, event, token, asset, source
}

public struct IntegrationMappingKey: Codable, Hashable, Sendable {
    public var kind: IntegrationMappingKind
    public var semanticID: String
    public init(kind: IntegrationMappingKind, semanticID: String) {
        self.kind = kind
        self.semanticID = semanticID
    }
    public var identifier: String { "\(kind.rawValue):\(semanticID)" }
}

/// Repository analysis can provide ambiguous/conflicting assessments without
/// squeezing them into IntegrationProfile's v1 string mappings.
public enum IntegrationMappingStatus: Codable, Equatable, Sendable {
    case resolved(String)
    case missing
    case empty
    case invalid
    case ambiguous
    case conflicting
}

public struct IntegrationMappingAssessment: Codable, Equatable, Sendable {
    public var key: IntegrationMappingKey
    public var status: IntegrationMappingStatus
    public init(key: IntegrationMappingKey, status: IntegrationMappingStatus) {
        self.key = key
        self.status = status
    }
}

public enum IntegrationIssueCode: String, Codable, Hashable, Sendable {
    case missingMapping, emptyMapping, invalidMapping, invalidRelation, ambiguousMapping
    case conflictingMapping, unsupportedTransform, missingDependency, unresolvedNilBehavior
}

public struct IntegrationResolutionIssue: Codable, Hashable, Sendable {
    public var code: IntegrationIssueCode
    public var semanticID: String
    public var output: SemanticOutputKey?
    public init(code: IntegrationIssueCode, semanticID: String, output: SemanticOutputKey? = nil) {
        self.code = code
        self.semanticID = semanticID
        self.output = output
    }
}

public enum IntegrationPlanner {
    public static func assessments(for contract: IntegrationContract,
                                   profile: IntegrationProfile) -> [IntegrationMappingAssessment] {
        var result: [IntegrationMappingAssessment] = []
        func append(_ kind: IntegrationMappingKind, _ id: String, _ value: String?) {
            let status: IntegrationMappingStatus
            if let value {
                status = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .resolved(value)
            } else {
                status = .missing
            }
            result.append(IntegrationMappingAssessment(
                key: IntegrationMappingKey(kind: kind, semanticID: id), status: status))
        }
        for input in Set(contract.inputs).sorted() { append(.input, input, profile.stateMappings[input]) }
        for event in Set(contract.events).sorted() { append(.event, event, profile.routingMappings[event]) }
        for token in Set(contract.tokenIDs).sorted(by: { $0.rawValue < $1.rawValue }) {
            append(.token, token.rawValue, profile.tokenMappings[token])
        }
        for asset in Set(contract.assetIDs).sorted(by: { $0.rawValue < $1.rawValue }) {
            append(.asset, asset.rawValue, profile.assetMappings[asset])
        }
        for source in Set((contract.semanticSources ?? []).map(\.key)).sorted() {
            append(.source, source.rawValue, profile.stateMappings[source.rawValue])
        }
        return result
    }

    public static func plan(_ contract: IntegrationContract,
                            assessments: [IntegrationMappingAssessment]) -> IntegrationPlan {
        var required = Set<IntegrationMappingKey>()
        for input in contract.inputs { required.insert(.init(kind: .input, semanticID: input)) }
        for event in contract.events { required.insert(.init(kind: .event, semanticID: event)) }
        for token in contract.tokenIDs { required.insert(.init(kind: .token, semanticID: token.rawValue)) }
        for asset in contract.assetIDs { required.insert(.init(kind: .asset, semanticID: asset.rawValue)) }
        for source in contract.semanticSources ?? [] {
            required.insert(.init(kind: .source, semanticID: source.key.rawValue))
        }

        let grouped = Dictionary(grouping: assessments.filter { required.contains($0.key) }, by: \.key)
        var issues = Set<IntegrationResolutionIssue>()
        var badMappings = Set<IntegrationMappingKey>()
        for key in required {
            let entries = grouped[key] ?? []
            let code: IntegrationIssueCode?
            if entries.count > 1 { code = .ambiguousMapping }
            else if let entry = entries.first {
                switch entry.status {
                case .resolved(let value):
                    code = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyMapping : nil
                case .missing: code = .missingMapping
                case .empty: code = .emptyMapping
                case .invalid: code = .invalidMapping
                case .ambiguous: code = .ambiguousMapping
                case .conflicting: code = .conflictingMapping
                }
            } else { code = .missingMapping }
            if let code {
                badMappings.insert(key)
                issues.insert(.init(code: code, semanticID: key.identifier))
            }
        }

        let sources = contract.semanticSources ?? []
        let sourceGroups = Dictionary(grouping: sources, by: \.key)
        let relations = contract.relations ?? []
        let relationGroups = Dictionary(grouping: relations, by: \.output)
        var blocked = Set<SemanticOutputKey>()
        for relation in relations {
            let output = relation.output
            if output.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                relationGroups[output, default: []].count != 1 {
                issues.insert(.init(code: .invalidRelation, semanticID: output.rawValue, output: output))
                blocked.insert(output)
            }
            for dependency in relation.dependencies {
                let declarations = sourceGroups[dependency] ?? []
                if declarations.isEmpty {
                    issues.insert(.init(code: .missingDependency, semanticID: dependency.rawValue, output: output))
                    blocked.insert(output)
                } else if declarations.count != 1 || dependency.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.insert(.init(code: .invalidRelation, semanticID: dependency.rawValue, output: output))
                    blocked.insert(output)
                }
                if badMappings.contains(.init(kind: .source, semanticID: dependency.rawValue)) { blocked.insert(output) }
            }
            if case .booleanEquals(let source, _) = relation.visibleWhen,
               let declarations = sourceGroups[source], declarations.count == 1,
               declarations[0].valueKind != .boolean {
                issues.insert(.init(code: .invalidRelation, semanticID: source.rawValue, output: output))
                blocked.insert(output)
            }
            if case .needsResolution = relation.whenNil {
                issues.insert(.init(code: .unresolvedNilBehavior, semanticID: relation.source.rawValue, output: output))
                blocked.insert(output)
            }
            // A transform key alone does not prove there is an implementation.
            // This slice implements only identity; Product transforms need a later adapter.
            if relation.transform != .identity {
                issues.insert(.init(code: .unsupportedTransform, semanticID: relation.transform.rawValue, output: output))
                blocked.insert(output)
            }
        }
        // The legacy input/event/token/asset lists have no output-level dependency
        // edges. Until those edges are represented, partial application cannot
        // prove independence from an unresolved legacy resource.
        if badMappings.contains(where: { $0.kind != .source }) {
            blocked.formUnion(relations.map(\.output))
        }
        let orderedIssues = issues.sorted {
            ($0.code.rawValue, $0.semanticID, $0.output?.rawValue ?? "") <
                ($1.code.rawValue, $1.semanticID, $1.output?.rawValue ?? "")
        }
        let mappingCodes: Set<IntegrationIssueCode> = [
            .missingMapping, .emptyMapping, .invalidMapping, .ambiguousMapping, .conflictingMapping
        ]
        return IntegrationPlan(
            contract: contract,
            unresolvedMappings: orderedIssues.filter { mappingCodes.contains($0.code) }.map(\.semanticID).sorted(),
            resolutionIssues: orderedIssues,
            blockedOutputs: blocked.sorted())
    }
}
