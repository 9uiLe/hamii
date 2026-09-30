import Foundation
import HamiiCore
import HamiiApplication
import HamiiFormat

// Test-only common JSON-value pipeline. No Package target or production parser
// accepts these prototype layouts. All timings execute in this Release process.
let folders = ["pages", "screens", "scopes", "components", "tokens", "assets",
               "interactions", "motions", "fixtures", "targets"]
struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError(message) }
}
func measured<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let result = try operation()
    return (result, (ProcessInfo.processInfo.systemUptime - start) * 1000)
}
func encode(_ value: Any) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: value,
        options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    data.append(0x0A)
    return data
}
func object(_ bytes: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else { throw ProbeError("Expected JSON object") }
    return value
}
func identity(_ value: [String: Any]) throws -> String {
    guard let id = (value["id"] as? [String: Any])?["rawValue"] as? String,
          !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    else { throw ProbeError("Invalid stable identity") }
    return id
}
func isCanonical(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    return path == "hamii.json" || path == "hamii-agent-profiles.json" ||
        (parts.count == 2 && folders.contains(String(parts[0])) && parts[1].hasSuffix(".json"))
}
func readFiles(_ root: URL, canonical: Bool) throws -> [String: Data] {
    let fm = FileManager.default
    var result: [String: Data] = [:]
    let paths: [String]
    if canonical {
        var found = ["hamii.json", "hamii-agent-profiles.json"]
        for folder in folders {
            let url = root.appendingPathComponent(folder)
            if fm.fileExists(atPath: url.path) {
                found += try fm.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".json") }
                    .map { folder + "/" + $0 }
            }
        }
        paths = found.sorted()
    } else {
        guard let enumerator = fm.enumerator(atPath: root.path) else { throw ProbeError("Missing candidate directory") }
        paths = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".json") }.sorted()
    }
    for path in paths {
        let url = root.appendingPathComponent(path)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        try check(attributes[.type] as? FileAttributeType == .typeRegular, "Non-regular input file")
        result[path] = try Data(contentsOf: url)
    }
    return result
}
func values(_ files: [String: Data]) throws -> [String: [String: Any]] {
    try files.mapValues(object)
}
func layoutValues(_ original: [String: [String: Any]], layout: String) throws -> [String: [String: Any]] {
    if layout == "CURRENT-N" { return original }
    if layout == "MONOLITHIC-N" { return ["document.json": original] }
    try check(layout == "SUBTREE-N", "Unknown normalized layout")
    var result: [String: [String: Any]] = [:]
    var seen: Set<String> = []
    for path in original.keys.sorted() {
        var value = original[path]!
        if path.hasPrefix("screens/") {
            guard var root = value["root"] as? [String: Any],
                  let children = root.removeValue(forKey: "children") as? [[String: Any]]
            else { throw ProbeError("Invalid Screen root") }
            var refs: [String] = []
            for child in children {
                let id = try identity(child)
                try check(seen.insert(id).inserted, "Duplicate subtree")
                refs.append(id)
                result["subtrees/\(id).json"] = child
            }
            root["prototypeChildrenRefs"] = refs
            value["root"] = root
        }
        result[path] = value
    }
    return result
}
func reconstructed(_ candidate: [String: [String: Any]], layout: String) throws -> [String: [String: Any]] {
    var result: [String: [String: Any]]
    if layout == "CURRENT-N" { result = candidate }
    else if layout == "MONOLITHIC-N" {
        try check(Set(candidate.keys) == ["document.json"], "Unknown aggregate files")
        guard let inventory = candidate["document.json"] as? [String: [String: Any]]
        else { throw ProbeError("Malformed aggregate inventory") }
        result = inventory
    } else {
        try check(layout == "SUBTREE-N", "Unknown reconstruction layout")
        result = [:]
        var used: Set<String> = []
        for path in candidate.keys.sorted() where !path.hasPrefix("subtrees/") {
            try check(isCanonical(path), "Unknown canonical path")
            var value = candidate[path]!
            if path.hasPrefix("screens/") {
                guard var root = value["root"] as? [String: Any], root["children"] == nil,
                      let refs = root.removeValue(forKey: "prototypeChildrenRefs") as? [String]
                else { throw ProbeError("Malformed Screen references") }
                var children: [[String: Any]] = []
                for id in refs {
                    let shard = "subtrees/\(id).json"
                    guard let child = candidate[shard] else { throw ProbeError("Dangling subtree reference") }
                    try check(used.insert(shard).inserted && identity(child) == id, "Duplicate/mismatched subtree")
                    children.append(child)
                }
                root["children"] = children
                value["root"] = root
            }
            result[path] = value
        }
        try check(Set(candidate.keys) == Set(result.keys).union(used), "Unreachable subtree")
    }
    try check(result.keys.allSatisfy(isCanonical), "Unknown reconstructed inventory path")
    return result
}
struct TestManifest: Decodable {
    let formatVersion: Int, id: EntityID, name: String, revision: Int, versions: FormatVersions
    let authoringHarness: AuthoringHarness, capabilityDeclarations: [CapabilityDeclaration]
    let tokenTemplate: TokenTemplateProvenance?
}
func document(_ inventory: [String: [String: Any]]) throws -> Document {
    guard let manifest = inventory["hamii.json"] else { throw ProbeError("Missing manifest") }
    let decoder = JSONDecoder()
    let header = try decoder.decode(TestManifest.self, from: encode(manifest))
    try check(header.formatVersion == 2 && header.versions.document == 2, "Non-current fixture")
    func entities<T: Decodable & Identifiable>(_ folder: String, _: T.Type) throws -> [T] where T.ID == EntityID {
        try inventory.keys.filter { $0.hasPrefix(folder + "/") }.sorted().map { path in
            let entity = try decoder.decode(T.self, from: encode(inventory[path]!))
            try check(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent == entity.id.rawValue,
                      "Current entity filename mismatch")
            return entity
        }
    }
    var doc = Document(name: header.name)
    doc.id = header.id; doc.revision = header.revision; doc.versions = header.versions
    doc.authoringHarness = header.authoringHarness; doc.capabilityDeclarations = header.capabilityDeclarations
    doc.tokenTemplate = header.tokenTemplate
    doc.pages = try entities("pages", Page.self); doc.screens = try entities("screens", Screen.self)
    doc.scopes = try entities("scopes", ArchitectureScope.self); doc.components = try entities("components", ComponentDefinition.self)
    doc.tokens = try entities("tokens", DesignToken.self); doc.assets = try entities("assets", Asset.self)
    doc.interactions = try entities("interactions", Interaction.self); doc.motions = try entities("motions", Motion.self)
    doc.fixtures = try entities("fixtures", PreviewFixture.self); doc.targets = try entities("targets", Target.self)
    return doc
}
func validate(_ doc: Document) throws {
    let diagnostics = DocumentValidator.validate(doc)
    try check(diagnostics.isEmpty, "Document validation: \(diagnostics.map(\.rule))")
}
func write(_ files: [String: Data], root: URL) throws {
    let fm = FileManager.default
    for path in files.keys.sorted() {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files[path]!.write(to: url)
    }
}
func metadata(_ files: [String: Data]) -> [String: Any] {
    let sizes = files.values.map(\.count).sorted()
    let mid = sizes.count / 2
    let median = sizes.count % 2 == 0 ? Double(sizes[mid - 1] + sizes[mid]) / 2 : Double(sizes[mid])
    return ["pathCount": sizes.count, "totalBytes": sizes.reduce(0, +),
            "largestShardBytes": sizes.last ?? 0, "medianShardBytes": median]
}
func openPrototype(_ root: URL, layout: String) throws -> (Document, [String: Any]) {
    let start = ProcessInfo.processInfo.systemUptime
    let (files, readMs) = try measured { try readFiles(root, canonical: false) }
    let (decoded, decodeMs) = try measured { try values(files) }
    let (inventory, reconstructMs) = try measured { try reconstructed(decoded, layout: layout) }
    // Same typed decode for all candidates; includes JSON-value re-encoding.
    let (doc, typedMs) = try measured { try document(inventory) }
    let (_, validationMs) = try measured { try validate(doc) }
    return (doc, ["totalMs": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                  "readMs": readMs, "decodeMs": decodeMs, "reconstructMs": reconstructMs,
                  "typedDecodeMs": typedMs, "validationMs": validationMs,
                  "filesRead": files.count, "bytesRead": files.values.reduce(0) { $0 + $1.count }])
}
func changedInventory(_ input: [String: [String: Any]], screenID: String, layerID: String) throws -> [String: [String: Any]] {
    var result = input
    let path = "screens/\(screenID).json"
    guard var screen = result[path], let root = screen["root"] as? [String: Any],
          var manifest = result["hamii.json"], let revision = manifest["revision"] as? Int
    else { throw ProbeError("Missing mutation source") }
    var matches = 0
    func changed(_ layer: [String: Any]) throws -> [String: Any] {
        var value = layer
        if try identity(layer) == layerID { value["text"] = "Changed!"; matches += 1 }
        guard let children = value["children"] as? [[String: Any]] else { throw ProbeError("Malformed Layer children") }
        value["children"] = try children.map(changed)
        return value
    }
    screen["root"] = try changed(root)
    try check(matches == 1, "Mutation target count mismatch")
    manifest["revision"] = revision + 1
    result[path] = screen; result["hamii.json"] = manifest
    return result
}
func negativeChecks(_ original: [String: [String: Any]]) throws -> [String] {
    let good = try layoutValues(original, layout: "SUBTREE-N")
    let screen = good.keys.sorted().first { $0.hasPrefix("screens/") }!
    let names = ["dangling", "duplicate", "unreachable", "unknown", "identity-mismatch"]
    for name in names {
        var bad = good, value = good[screen]!, root = good[screen]!["root"] as! [String: Any]
        var refs = root["prototypeChildrenRefs"] as! [String]
        switch name {
        case "dangling": refs[0] = "missing"
        case "duplicate": refs.append(refs[0])
        case "unreachable": bad["subtrees/unused.json"] = good["subtrees/\(refs[0]).json"]
        case "unknown": bad["unknown.json"] = [:]
        default:
            var child = bad["subtrees/\(refs[0]).json"]!
            child["id"] = ["rawValue": "different"]
            bad["subtrees/\(refs[0]).json"] = child
        }
        root["prototypeChildrenRefs"] = refs; value["root"] = root; bad[screen] = value
        var rejected = false
        do { _ = try reconstructed(bad, layout: "SUBTREE-N") } catch { rejected = true }
        try check(rejected, "Negative reference accepted: \(name)")
    }
    return names
}
struct CaseSpec: Decodable {
    let scale: Int, source: String, destination: String, screenID: String, layerID: String
}
func scaling(_ spec: CaseSpec) throws -> [String: Any] {
    let fm = FileManager.default
    let source = URL(fileURLWithPath: spec.source), destination = URL(fileURLWithPath: spec.destination)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let files = try readFiles(source, canonical: true), original = try values(files)
    let baseline = try CanonicalRepository(root: source).load()
    let expected = try MutationEngine.apply([.setText(screenID: EntityID(spec.screenID), layerID: EntityID(spec.layerID), text: "Changed!")],
        to: baseline, expectedRevision: baseline.revision, author: .human, agent: nil).0
    let after = try changedInventory(original, screenID: spec.screenID, layerID: spec.layerID)
    try check(try document(after) == expected, "Shared semantic delta mismatch")
    let repository = CanonicalRepository(root: source)
    _ = try repository.load(); _ = try repository.observe() // warm-up, outside series
    var load: [Double] = [], observe: [Double] = [], productionSave: [Double] = []
    for _ in 0..<10 {
        let (doc, ms) = try measured { try repository.load() }
        try check(doc == baseline, "Production load mismatch"); load.append(ms)
        let (observation, observationMs) = try measured { try repository.observe() }
        try check(observation.document == baseline, "Production observe mismatch"); observe.append(observationMs)
    }
    for run in 0..<5 {
        let copy = destination.appendingPathComponent("production-save-\(run)")
        try fm.copyItem(at: source, to: copy)
        let copyRepository = CanonicalRepository(root: copy), service = ProjectService(repository: copyRepository)
        let observed = try service.observe()
        let (_, ms) = try measured {
            try service.mutate(.setText(screenID: EntityID(spec.screenID), layerID: EntityID(spec.layerID), text: "Changed!"),
                               expectedState: observed.statePrecondition, author: .human)
        }
        try check(try copyRepository.load() == expected, "Production save delta mismatch")
        productionSave.append(ms)
    }
    var rows: [[String: Any]] = []
    for layout in ["CURRENT-N", "MONOLITHIC-N", "SUBTREE-N"] {
        let valuesBefore = try layoutValues(original, layout: layout)
        let encoded = try valuesBefore.mapValues(encode)
        let root = destination.appendingPathComponent(layout)
        try write(encoded, root: root)
        for run in 0..<3 {
            let repeated = try layoutValues(original, layout: layout).mapValues(encode)
            try check(repeated == encoded, "Nondeterministic candidate")
            let reconstructed = try reconstructed(values(readFiles(root, canonical: false)), layout: layout)
            try check(try encode(reconstructed) == encode(original), "Round-trip inventory mismatch")
            let canonical = destination.appendingPathComponent("validate-\(layout)-\(run)")
            try write(reconstructed.mapValues(encode), root: canonical)
            try check(try CanonicalRepository(root: canonical).load() == baseline, "Actual Current parser mismatch")
        }
        _ = try openPrototype(root, layout: layout) // one warm-up
        var opens: [[String: Any]] = [], saves: [[String: Any]] = []
        for _ in 0..<10 {
            let (doc, metric) = try openPrototype(root, layout: layout)
            try check(doc == baseline, "Prototype typed decode mismatch"); opens.append(metric)
        }
        for run in 0..<5 {
            let copy = destination.appendingPathComponent("prototype-save-\(layout)-\(run)")
            try fm.copyItem(at: root, to: copy)
            let start = ProcessInfo.processInfo.systemUptime
            let (newFiles, encodeMs) = try measured {
                let delta = try changedInventory(original, screenID: spec.screenID, layerID: spec.layerID)
                return try layoutValues(delta, layout: layout).mapValues(encode)
            }
            let changedFiles = newFiles.filter { encoded[$0.key] != $0.value }
            let (_, writeMs) = try measured { try write(changedFiles, root: copy) }
            let total = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let result = try reconstructed(values(readFiles(copy, canonical: false)), layout: layout)
            try check(try encode(result) == encode(after), "Prototype save unintended delta")
            let validateRoot = destination.appendingPathComponent("validate-save-\(layout)-\(run)")
            try write(result.mapValues(encode), root: validateRoot)
            try check(try CanonicalRepository(root: validateRoot).load() == expected, "Prototype saved Current parse mismatch")
            saves.append(["totalMs": total, "encodeMs": encodeMs, "writeMs": writeMs,
                          "changedPaths": changedFiles.keys.sorted(), "changedPathCount": changedFiles.count,
                          "replacementBytes": changedFiles.values.reduce(0) { $0 + $1.count },
                          "totalCandidateBytes": newFiles.values.reduce(0) { $0 + $1.count }])
        }
        rows.append(["layout": layout, "serializer": "Foundation.JSONSerialization: sortedKeys/prettyPrinted/withoutEscapingSlashes/LF",
                     "metadata": metadata(encoded), "roundTripCount": 3, "roundTripValid": true,
                     "currentValidationValid": true, "deterministic": true, "openSamples": opens,
                     "saveSamples": saves, "productionLoadMs": NSNull(), "productionObserveMs": NSNull(),
                     "productionMutationSaveMs": NSNull()])
    }
    return ["scale": spec.scale, "production": ["layout": "CURRENT-P", "metadata": metadata(files),
            "loadSamplesMs": load, "observeSamplesMs": observe, "mutationSaveSamplesMs": productionSave,
            "filesRead": NSNull(), "bytesRead": NSNull(), "readCountsStatus": "unmeasured public Release API"],
            "negativeReferenceRejections": try negativeChecks(original), "normalized": rows,
            "peakRSS": NSNull(), "peakRSSStatus": "unmeasured"]
}

// Modes: serialize consumes a base64 byte inventory envelope; scaling writes its
// result to a file. Failures are surfaced to the orchestrator, which retains the
// incomplete/failed trial and does not publish success.
do {
    let args = CommandLine.arguments
    if args.count == 3 && args[1] == "serialize" {
        struct Envelope: Decodable { let files: [String: Data] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let result = try layoutValues(values(envelope.files), layout: args[2]).mapValues(encode)
        FileHandle.standardOutput.write(try JSONEncoder().encode(["files": result]))
    } else if args.count == 4 && args[1] == "scaling" {
        let spec = try JSONDecoder().decode(CaseSpec.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        try encode(scaling(spec)).write(to: URL(fileURLWithPath: args[3]))
    } else { throw ProbeError("usage: serialize LAYOUT | scaling SPEC OUTPUT") }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
