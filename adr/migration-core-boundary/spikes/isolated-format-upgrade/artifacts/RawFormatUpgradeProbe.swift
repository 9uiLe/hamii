import Foundation

/// Test-only edge graph. Historical JSON never enters a current-domain type.
public enum RawFormatUpgradeProbe {
    public typealias Files = [String: Data]
    public typealias Validator = (Files, Int) throws -> Void

    public enum Failure: Error, Equatable {
        case invalidInput(String)
        case noPath(Int, Int)
        case downgrade(Int, Int)
        case injected(Int)
    }

    public struct Candidate {
        public let files: Files
        public let edges: [String]
        public let classification: String
        public let diagnostics: [String]
        public let validatedVersions: [Int]
    }

    public static func migrate(_ source: Files, to target: Int, failAfterEdge: Int? = nil,
                               validate: Validator) throws -> Candidate {
        let sourceVersion = try version(source)
        guard target >= sourceVersion else { throw Failure.downgrade(sourceVersion, target) }
        guard (1...3).contains(target), (1...3).contains(sourceVersion) else {
            throw Failure.noPath(sourceVersion, target)
        }
        try validate(source, sourceVersion)
        var candidate = source
        var edges: [String] = []
        var validatedVersions = [sourceVersion]
        if sourceVersion < target { for next in (sourceVersion + 1)...target {
            switch next {
            case 2: candidate = try v1ToV2(candidate)
            case 3: candidate = try v2ToV3(candidate)
            default: throw Failure.noPath(sourceVersion, target)
            }
            try validate(candidate, next)
            validatedVersions.append(next)
            edges.append("\(next - 1)->\(next)")
            if failAfterEdge == next { throw Failure.injected(next) }
        } }
        return Candidate(files: candidate, edges: edges,
                         classification: edges.contains("2->3") ? "losslessWithNormalization" : "lossless",
                         diagnostics: [], validatedVersions: validatedVersions)
    }

    public static func version(_ files: Files) throws -> Int {
        guard let bytes = files["hamii.json"], let manifest = try? object(bytes),
              let format = manifest["formatVersion"] as? Int,
              let versions = manifest["versions"] as? [String: Any],
              let document = versions["document"] as? Int, format == document else {
            throw Failure.invalidInput("manifest version markers disagree")
        }
        return format
    }

    private static func v1ToV2(_ files: Files) throws -> Files {
        guard try version(files) == 1 else { throw Failure.invalidInput("expected v1") }
        var next = files
        for path in files.keys.sorted() where path.hasPrefix("screens/") || path.hasPrefix("components/") {
            guard path.hasSuffix(".json"), let bytes = files[path] else { continue }
            var json = try object(bytes)
            guard let root = json["root"] as? [String: Any] else { throw Failure.invalidInput("missing root: \(path)") }
            json["root"] = try upgradeLayer(root)
            next[path] = try encoded(json)
        }
        try changeVersion(&next, from: 1, to: 2)
        return next
    }

    private static func v2ToV3(_ files: Files) throws -> Files {
        guard try version(files) == 2 else { throw Failure.invalidInput("expected v2") }
        var next = files
        // Synthetic v3 adds no product semantics. Only the two version markers advance.
        try changeVersion(&next, from: 2, to: 3)
        return next
    }

    private static func upgradeLayer(_ input: [String: Any]) throws -> [String: Any] {
        var node = input
        if var layout = node["layout"] as? [String: Any], let token = layout.removeValue(forKey: "paddingTokenID") {
            guard let tokenObject = token as? [String: Any],
                  let tokenID = tokenObject["rawValue"] as? String, !tokenID.isEmpty,
                  node["effects"] == nil else {
                throw Failure.invalidInput("ambiguous padding effect")
            }
            node["layout"] = layout
            node["effects"] = [["kind": "padding", "tokenID": tokenObject]]
        }
        if let children = node["children"] as? [[String: Any]] {
            node["children"] = try children.map(upgradeLayer)
        }
        if var component = node["component"] as? [String: Any],
           var slots = component["slotContent"] as? [String: [[String: Any]]] {
            for name in slots.keys.sorted() { slots[name] = try slots[name]!.map(upgradeLayer) }
            component["slotContent"] = slots
            node["component"] = component
        }
        return node
    }

    private static func changeVersion(_ files: inout Files, from old: Int, to new: Int) throws {
        guard try version(files) == old, let bytes = files["hamii.json"] else {
            throw Failure.invalidInput("version transition mismatch")
        }
        var manifest = try object(bytes)
        var versions = manifest["versions"] as! [String: Any]
        manifest["formatVersion"] = new
        versions["document"] = new
        manifest["versions"] = versions
        files["hamii.json"] = try encoded(manifest)
    }

    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw Failure.invalidInput("not a JSON object")
        }
        return value
    }

    private static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) + Data([0x0a])
    }
}
