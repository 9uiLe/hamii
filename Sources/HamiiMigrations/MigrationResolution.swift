import Foundation

/// Git and the exact Canonical byte identity are supplied by the runtime. The
/// historical migration edge never reads a worktree or calculates its SHA-256.
public struct MigrationResolutionSourceBinding: Codable, Equatable {
    public let sourceOID: String
    public let sourceCanonicalIdentity: String
    public let sourceFormatVersion: Int
    public let targetFormatVersion: Int

    public init(sourceOID: String, sourceCanonicalIdentity: String,
                sourceFormatVersion: Int = 1, targetFormatVersion: Int = 2) {
        self.sourceOID = sourceOID
        self.sourceCanonicalIdentity = sourceCanonicalIdentity
        self.sourceFormatVersion = sourceFormatVersion
        self.targetFormatVersion = targetFormatVersion
    }
}

public struct MigrationResolutionItemID: Codable, Hashable, Sendable {
    public let code: String
    public let path: String
    public let entityID: String?
    /// Stable, non-cryptographic discriminator within an exact source binding.
    public let historicalValueFingerprint: String
}

public struct MigrationResolutionChoice: Codable, Equatable {
    public let id: String
    public let affectedSemantic: String
    public let affectedPaths: [String]
    public let affectedEntityIDs: [String]
    public let lossClass: MigrationClassification
}

public struct MigrationResolutionItem: Codable, Equatable {
    public let id: MigrationResolutionItemID
    public let diagnostic: MigrationDiagnostic
    public let choices: [MigrationResolutionChoice]
}

public struct MigrationResolutionReport: Codable {
    public let source: MigrationResolutionSourceBinding
    public let classification: MigrationClassification
    public let items: [MigrationResolutionItem]
}

public struct MigrationResolutionDecision: Codable, Equatable {
    public let item: MigrationResolutionItemID
    public let selectedCandidateID: String

    public init(item: MigrationResolutionItemID, selectedCandidateID: String) {
        self.item = item
        self.selectedCandidateID = selectedCandidateID
    }
}

public struct MigrationResolutionManifest: Codable, Equatable {
    public let formatVersion: Int
    public let sourceOID: String
    public let sourceCanonicalIdentity: String
    public let sourceFormatVersion: Int
    public let targetFormatVersion: Int
    public let decisions: [MigrationResolutionDecision]

    public init(source: MigrationResolutionSourceBinding, decisions: [MigrationResolutionDecision]) {
        formatVersion = 1
        sourceOID = source.sourceOID
        sourceCanonicalIdentity = source.sourceCanonicalIdentity
        sourceFormatVersion = source.sourceFormatVersion
        targetFormatVersion = source.targetFormatVersion
        self.decisions = decisions
    }

    public var sourceBinding: MigrationResolutionSourceBinding {
        MigrationResolutionSourceBinding(sourceOID: sourceOID,
            sourceCanonicalIdentity: sourceCanonicalIdentity,
            sourceFormatVersion: sourceFormatVersion, targetFormatVersion: targetFormatVersion)
    }

    /// JSONDecoder ignores unknown fields; a migration decision must not.
    public static func decodeStrict(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationResolutionFailure.invalidManifest
        }
        try requireKeys(root, exactly: ["formatVersion", "sourceOID", "sourceCanonicalIdentity",
                                        "sourceFormatVersion", "targetFormatVersion", "decisions"])
        guard let decisions = root["decisions"] as? [[String: Any]] else {
            throw MigrationResolutionFailure.invalidManifest
        }
        for decision in decisions {
            try requireKeys(decision, exactly: ["item", "selectedCandidateID"])
            guard let item = decision["item"] as? [String: Any] else {
                throw MigrationResolutionFailure.invalidManifest
            }
            let required: Set<String> = ["code", "path", "historicalValueFingerprint"]
            let keys = Set(item.keys)
            guard keys == required || keys == required.union(["entityID"]) else {
                throw MigrationResolutionFailure.invalidManifest
            }
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.formatVersion == 1, result.sourceFormatVersion == 1,
              result.targetFormatVersion == 2, !result.sourceOID.isEmpty,
              !result.sourceCanonicalIdentity.isEmpty else {
            throw MigrationResolutionFailure.invalidManifest
        }
        return result
    }

    private static func requireKeys(_ value: [String: Any], exactly keys: Set<String>) throws {
        guard Set(value.keys) == keys else { throw MigrationResolutionFailure.invalidManifest }
    }
}

public struct MigrationResolutionLoss: Codable, Equatable {
    public let item: MigrationResolutionItemID
    public let choiceID: String
    public let path: String
    public let entityID: String?
    public let historicalValue: String
    public let affectedSemantic: String
}

public enum MigrationResolutionFailure: Error, CustomStringConvertible {
    case invalidManifest
    case staleSource
    case invalidChoice
    case unresolved([MigrationResolutionItemID])

    public var description: String {
        switch self {
        case .invalidManifest: "Invalid migration resolution manifest"
        case .staleSource: "Migration resolution is bound to a different Canonical source"
        case .invalidChoice: "Migration resolution contains an unknown or conflicting choice"
        case .unresolved(let items): "Migration remains blocked by \(items.count) unresolved item(s)"
        }
    }
}

extension MigrationRegistry {
    public static func resolutionReport(_ source: MigrationFileSet,
                                        sourceBinding: MigrationResolutionSourceBinding) throws -> MigrationResolutionReport {
        guard sourceBinding.sourceFormatVersion == 1, sourceBinding.targetFormatVersion == 2,
              try FormatV1.markers(in: source.files) == 1,
              try route(from: 1, to: 2).edgePath == ["1->2"] else {
            throw MigrationResolutionFailure.invalidManifest
        }
        let analysis = try analyze(source)
        let declarations = try resolutionDeclarations(source.files)
        let items = try analysis.diagnostics.map { diagnostic -> MigrationResolutionItem in
            let relevant: Data
            var choices: [MigrationResolutionChoice] = []
            switch diagnostic.code {
            case "capability.ambiguousSpacing":
                let matching = declarations.enumerated().filter { _, value in
                    declarationTarget(value) == diagnostic.entityID && declarationKey(value) == "token.spacing"
                }
                relevant = try canonicalJSON(matching.map(\.element))
                let equivalent = try Set(matching.map { try canonicalJSON($0.element) }).count == 1
                choices = try matching.map { index, value in
                    MigrationResolutionChoice(id: "spacing:\(index):\(fingerprint(try canonicalJSON(value)))",
                        affectedSemantic: "v2 effect.padding and retained token.spacing declarations",
                        affectedPaths: [diagnostic.path], affectedEntityIDs: diagnostic.entityID.map { [$0] } ?? [],
                        lossClass: equivalent ? .losslessWithNormalization : .potentiallyLossy)
                }
            case "layer.crossKindResidual":
                let value = try residualValue(source.files, diagnostic: diagnostic)
                relevant = try canonicalJSON(value)
                if let key = diagnostic.path.split(separator: ".").last.map(String.init),
                   ["text", "textBinding", "emittedEvent", "assetID", "component"].contains(key) {
                    choices = [MigrationResolutionChoice(id: "discard:\(fingerprint(relevant))",
                        affectedSemantic: "historical cross-kind \(key) residual",
                        affectedPaths: [diagnostic.path], affectedEntityIDs: diagnostic.entityID.map { [$0] } ?? [],
                        lossClass: .potentiallyLossy)]
                }
            default:
                let path = source.files.keys.sorted { $0.count > $1.count }.first {
                    diagnostic.path == $0 || diagnostic.path.hasPrefix($0 + ".")
                }
                relevant = path.flatMap { source.files[$0] } ?? Data(diagnostic.path.utf8)
            }
            let identityBytes = Data((diagnostic.code + "\0" + diagnostic.path + "\0" +
                                      (diagnostic.entityID ?? "") + "\0").utf8) + relevant
            let id = MigrationResolutionItemID(code: diagnostic.code, path: diagnostic.path,
                entityID: diagnostic.entityID, historicalValueFingerprint: fingerprint(identityBytes))
            return MigrationResolutionItem(id: id, diagnostic: diagnostic, choices: choices)
        }
        return MigrationResolutionReport(source: sourceBinding,
            classification: analysis.classification ?? .manual, items: items)
    }

    public static func transform(_ source: MigrationFileSet, applying manifest: MigrationResolutionManifest,
                                 actualSourceBinding: MigrationResolutionSourceBinding) throws -> MigrationCandidate {
        guard manifest.formatVersion == 1 else { throw MigrationResolutionFailure.invalidManifest }
        guard manifest.sourceBinding == actualSourceBinding else { throw MigrationResolutionFailure.staleSource }
        let report = try resolutionReport(source, sourceBinding: actualSourceBinding)
        var selected: [(MigrationResolutionItem, MigrationResolutionChoice)] = []
        var seen = Set<MigrationResolutionItemID>()
        for decision in manifest.decisions {
            guard seen.insert(decision.item).inserted,
                  let item = report.items.first(where: { $0.id == decision.item }),
                  let choice = item.choices.first(where: { $0.id == decision.selectedCandidateID }) else {
                throw MigrationResolutionFailure.invalidChoice
            }
            selected.append((item, choice))
        }
        let unresolved = report.items.filter { !seen.contains($0.id) }.map(\.id)
        guard unresolved.isEmpty else { throw MigrationResolutionFailure.unresolved(unresolved) }

        var edited = source.files
        var losses: [MigrationResolutionLoss] = []
        let originalDeclarations = try resolutionDeclarations(source.files)
        var selectedSpacing: [String: (Int, MigrationResolutionItem, MigrationResolutionChoice)] = [:]
        for (item, choice) in selected where item.diagnostic.code == "capability.ambiguousSpacing" {
            guard let target = item.diagnostic.entityID,
                  let index = Int(choice.id.split(separator: ":")[1]),
                  originalDeclarations.indices.contains(index),
                  declarationTarget(originalDeclarations[index]) == target,
                  declarationKey(originalDeclarations[index]) == "token.spacing" else {
                throw MigrationResolutionFailure.invalidChoice
            }
            selectedSpacing[target] = (index, item, choice)
        }
        if !selectedSpacing.isEmpty {
            var manifestObject = try jsonObject(edited["hamii.json"])
            var retained: [[String: Any]] = []
            for (index, declaration) in originalDeclarations.enumerated() {
                if let target = declarationTarget(declaration), declarationKey(declaration) == "token.spacing",
                   let selected = selectedSpacing[target], index != selected.0 {
                    if try canonicalJSON(declaration) != canonicalJSON(originalDeclarations[selected.0]) {
                        losses.append(MigrationResolutionLoss(item: selected.1.id, choiceID: selected.2.id,
                            path: "hamii.json.capabilityDeclarations[\(index)]", entityID: target,
                            historicalValue: try jsonString(declaration), affectedSemantic: selected.2.affectedSemantic))
                    }
                } else {
                    retained.append(declaration)
                }
            }
            manifestObject["capabilityDeclarations"] = retained
            edited["hamii.json"] = try canonicalJSON(manifestObject)
        }
        for (item, choice) in selected where item.diagnostic.code == "layer.crossKindResidual" {
            guard let id = item.diagnostic.entityID,
                  let key = item.diagnostic.path.split(separator: ".").last.map(String.init),
                  let file = edited.keys.first(where: { item.diagnostic.path.hasPrefix($0 + ".root") }),
                  let historical = try? residualValue(source.files, diagnostic: item.diagnostic) else {
                throw MigrationResolutionFailure.invalidChoice
            }
            var entity = try jsonObject(edited[file])
            guard var root = entity["root"] as? [String: Any], removeResidual(&root, id: id, key: key) else {
                throw MigrationResolutionFailure.invalidChoice
            }
            entity["root"] = root
            edited[file] = try canonicalJSON(entity)
            losses.append(MigrationResolutionLoss(item: item.id, choiceID: choice.id,
                path: item.diagnostic.path, entityID: id, historicalValue: try jsonString(historical),
                affectedSemantic: choice.affectedSemantic))
        }
        let post = try analyze(MigrationFileSet(files: edited))
        guard post.diagnostics.isEmpty else { throw MigrationResolutionFailure.unresolved(try resolutionReport(
            MigrationFileSet(files: edited), sourceBinding: actualSourceBinding).items.map(\.id)) }
        let base = try transform(MigrationFileSet(files: edited))
        return MigrationCandidate(files: base.files, sourceVersion: base.sourceVersion,
            targetVersion: base.targetVersion, edgePath: base.edgePath,
            classification: losses.isEmpty ? .losslessWithNormalization : .potentiallyLossy,
            diagnostics: report.items.map(\.diagnostic),
            resolutionDecisions: manifest.decisions, losses: losses,
            remainingUnresolved: [])
    }
}

private func resolutionDeclarations(_ files: [String: Data]) throws -> [[String: Any]] {
    guard let values = try jsonObject(files["hamii.json"])["capabilityDeclarations"] as? [[String: Any]] else {
        throw MigrationResolutionFailure.invalidManifest
    }
    return values
}

private func declarationTarget(_ value: [String: Any]) -> String? {
    (value["targetID"] as? [String: Any])?["rawValue"] as? String
}

private func declarationKey(_ value: [String: Any]) -> String? {
    (value["key"] as? [String: Any])?["rawValue"] as? String
}

private func canonicalJSON(_ value: Any) throws -> Data {
    var bytes = try JSONSerialization.data(withJSONObject: value,
        options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
    bytes.append(0x0A)
    return bytes
}

private func jsonString(_ value: Any) throws -> String {
    String(decoding: try canonicalJSON(value), as: UTF8.self)
}

private func jsonObject(_ bytes: Data?) throws -> [String: Any] {
    guard let bytes, let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw MigrationResolutionFailure.invalidManifest
    }
    return result
}

private func fingerprint(_ bytes: Data) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(format: "fnv64:%016llx", value)
}

private func residualValue(_ files: [String: Data], diagnostic: MigrationDiagnostic) throws -> Any {
    guard let id = diagnostic.entityID,
          let file = files.keys.first(where: { diagnostic.path.hasPrefix($0 + ".root") }),
          let root = try jsonObject(files[file])["root"] as? [String: Any],
          let found = findLayer(root, id: id),
          let key = diagnostic.path.split(separator: ".").last.map(String.init),
          let value = found[key] else { throw MigrationResolutionFailure.invalidChoice }
    return value
}

private func findLayer(_ value: [String: Any], id: String) -> [String: Any]? {
    if (value["id"] as? [String: Any])?["rawValue"] as? String == id { return value }
    for child in value["children"] as? [[String: Any]] ?? [] {
        if let result = findLayer(child, id: id) { return result }
    }
    if let slots = (value["component"] as? [String: Any])?["slotContent"] as? [String: Any] {
        for name in slots.keys.sorted() {
            for child in slots[name] as? [[String: Any]] ?? [] {
                if let result = findLayer(child, id: id) { return result }
            }
        }
    }
    return nil
}

private func removeResidual(_ value: inout [String: Any], id: String, key: String) -> Bool {
    if (value["id"] as? [String: Any])?["rawValue"] as? String == id {
        value.removeValue(forKey: key)
        return true
    }
    if var children = value["children"] as? [[String: Any]] {
        for index in children.indices where removeResidual(&children[index], id: id, key: key) {
            value["children"] = children
            return true
        }
    }
    if var component = value["component"] as? [String: Any],
       var slots = component["slotContent"] as? [String: Any] {
        for name in slots.keys.sorted() {
            guard var children = slots[name] as? [[String: Any]] else { continue }
            for index in children.indices where removeResidual(&children[index], id: id, key: key) {
                slots[name] = children
                component["slotContent"] = slots
                value["component"] = component
                return true
            }
        }
    }
    return false
}
