import Foundation

/// Raw, adjacent Format v2 → v3 transformation. Target semantic validation is
/// owned by the migration runtime, not by this historical format module.
enum FormatV2 {
    static func validate(_ files: [String: Data]) throws {
        guard let bytes = files["hamii.json"],
              let manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let versions = manifest["versions"] as? [String: Any],
              exactInteger(manifest["formatVersion"], equals: 2),
              exactInteger(versions["document"], equals: 2) else {
            throw MigrationEdgeFailure.invalidInput("Format v2→v3 requires exact 2/2 document markers")
        }
        for path in files.keys.sorted() where isScreen(path) {
            guard let bytes = files[path],
                  let screen = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw MigrationEdgeFailure.invalidInput("Expected Screen object at \(path)")
            }
            guard screen["semantics"] == nil else {
                throw MigrationEdgeFailure.invalidInput("Screen semantics requires format v3: \(path)")
            }
        }
    }

    static func upgrade(_ files: [String: Data]) throws -> [String: Data] {
        try validate(files)
        var candidate = files
        var manifest = try object(files["hamii.json"], path: "hamii.json")
        guard var versions = manifest["versions"] as? [String: Any] else {
            throw MigrationEdgeFailure.invalidInput("Expected object at hamii.json.versions")
        }
        versions["document"] = 3
        manifest["versions"] = versions
        manifest["formatVersion"] = 3
        candidate["hamii.json"] = try encoded(manifest)
        for path in files.keys.sorted() where isScreen(path) {
            var screen = try object(files[path], path: path)
            screen["semantics"] = ["sources": [], "outputs": [], "relations": []] as [String: [Any]]
            candidate[path] = try encoded(screen)
        }
        return candidate
    }

    private static func isScreen(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0] == "screens" && parts[1].hasSuffix(".json")
    }

    private static func exactInteger(_ value: Any?, equals expected: Int) -> Bool {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue == Double(number.intValue) else { return false }
        return number.intValue == expected
    }

    private static func object(_ bytes: Data?, path: String) throws -> [String: Any] {
        guard let bytes, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw MigrationEdgeFailure.invalidInput("Expected object at \(path)")
        }
        return object
    }

    private static func encoded(_ value: [String: Any]) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        bytes.append(0x0A)
        return bytes
    }
}
