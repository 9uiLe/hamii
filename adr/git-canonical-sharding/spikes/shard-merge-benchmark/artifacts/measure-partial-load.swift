import Foundation
import CryptoKit
import HamiiCore
import HamiiFormat

// Linked only as a disposable Release experiment. The shared JSON/layout/full
// oracle helpers are extracted from measure-open-save-scaling.swift by the runner.
struct PartialSpec: Decodable {
    let root: String, canonical: String, layout: String, screenID: String, subtreeID: String, layerID: String
    let sourceFingerprint: String
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func fingerprint(_ files: [String: Data]) -> String {
    var data = Data()
    for path in files.keys.sorted() {
        data.append(Data("\(path.utf8.count):\(path):\(files[path]!.count):".utf8))
        data.append(files[path]!)
    }
    return digest(data)
}
func typed<T: Decodable>(_ value: Any, _ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: encode(value))
}
func asObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try object(JSONEncoder().encode(value))
}
func walk(_ layer: Layer) -> [Layer] {
    [layer] + layer.children.flatMap(walk) + (layer.component?.slotContent.keys.sorted().flatMap {
        layer.component!.slotContent[$0]!.flatMap(walk)
    } ?? [])
}
struct PartialSemanticSlice {
    let bytes: Data
    let globalValidityProven = false
    let authoringReady = false
}

// Every actual open is instrumented here. No enumeration or full decoder in this
// reader; only request IDs, stable paths and already-loaded explicit references.
final class SliceReader {
    let root: URL, layout: String
    var cache: [String: [String: Any]] = [:]
    var paths: [String] = [], sizes: [String: Int] = [:]
    var readMs = 0.0, decodeMs = 0.0
    init(_ root: URL, _ layout: String) { self.root = root; self.layout = layout }
    func file(_ path: String) throws -> [String: Any] {
        if let value = cache[path] { return value }
        try check(isCanonical(path) || path == "document.json" ||
                  (path.hasPrefix("subtrees/") && path.split(separator: "/").count == 2), "Unknown input path")
        let url = root.appendingPathComponent(path)
        let (data, read) = try measured {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try check(attributes[.type] as? FileAttributeType == .typeRegular, "Non-regular input")
            return try Data(contentsOf: url)
        }
        readMs += read; paths.append(path); sizes[path] = data.count
        let (value, decode) = try measured { try object(data) }
        decodeMs += decode; cache[path] = value
        return value
    }
    func value(_ path: String) throws -> [String: Any] {
        if layout == "MONOLITHIC-N" {
            guard let value = try file("document.json")[path] as? [String: Any] else { throw ProbeError("Required aggregate entry missing: \(path)") }
            return value
        }
        return try file(path)
    }
    func entity<T: Decodable & Identifiable>(_ folder: String, _ id: String, _ type: T.Type) throws -> (T, [String: Any]) where T.ID == EntityID {
        try check(!id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }, "Unsafe reference")
        let value = try self.value("\(folder)/\(id).json")
        let (result, time) = try measured { try typed(value, type) }
        decodeMs += time
        try check(result.id.rawValue == id, "Required entity path/identity mismatch")
        return (result, value)
    }
    func subtree(_ id: String) throws -> Layer {
        try check(!id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }, "Unknown subtree reference")
        let value = try file("subtrees/\(id).json")
        try check(identity(value) == id, "Subtree path identity mismatch")
        let (layer, time) = try measured { try typed(value, Layer.self) }
        decodeMs += time; return layer
    }
    func selected(_ spec: PartialSpec, task: String) throws -> (Layer, [String: Any], Screen?) {
        let value = try self.value("screens/\(spec.screenID).json")
        try check(identity(value) == spec.screenID, "Screen path mismatch")
        guard let rawRoot = value["root"] as? [String: Any] else { throw ProbeError("Missing Screen root") }
        var screenValue = value
        var roots: [Layer] = []
        if layout == "SUBTREE-N" {
            guard rawRoot["children"] == nil, let refs = rawRoot["prototypeChildrenRefs"] as? [String] else { throw ProbeError("Malformed subtree refs") }
            try check(Set(refs).count == refs.count && refs.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } }, "Duplicate/unknown subtree refs")
            if task == "A" {
                try check(refs.contains(spec.subtreeID), "Selected subtree ref missing")
                roots = [try subtree(spec.subtreeID)]
            } else {
                for ref in refs {
                    let layer = try subtree(ref); roots.append(layer)
                    if task == "C" && walk(layer).contains(where: { $0.id.rawValue == spec.layerID }) { break }
                }
            }
            var restored = rawRoot; restored.removeValue(forKey: "prototypeChildrenRefs")
            restored["children"] = try roots.map(asObject); screenValue["root"] = restored
        }
        let (screen, time) = try measured { try typed(screenValue, Screen.self) }; decodeMs += time
        let context: [String: Any] = ["id": try asObject(screen.id), "name": screen.name, "scopeID": try asObject(screen.scopeID)]
        if task == "A" {
            guard let root = screen.root.children.first(where: { $0.id.rawValue == spec.subtreeID }) else { throw ProbeError("Selected subtree missing") }
            return (root, context, nil)
        }
        if task == "C" {
            guard let found = walk(screen.root).first(where: { $0.id.rawValue == spec.layerID }) else { throw ProbeError("Layer ID missing") }
            return (found, context, nil)
        }
        if case .custom(let id) = screen.navigation { try check(walk(screen.root).contains { $0.id == id }, "Custom navigation target missing") }
        return (screen.root, context, screen)
    }
    func slice(_ spec: PartialSpec, task: String) throws -> (PartialSemanticSlice, [String: Any]) {
        let start = ProcessInfo.processInfo.systemUptime
        let manifest = try value("hamii.json")
        let (header, headerTime) = try measured { try typed(manifest, TestManifest.self) }; decodeMs += headerTime
        try check(header.formatVersion == 2, "Unsupported manifest")
        let (layer, context, screen) = try selected(spec, task: task)
        var dependencies: [String: [String: [String: Any]]] = [:]
        var active: Set<String> = []
        func resource<T: Decodable & Identifiable>(_ folder: String, _ id: EntityID, _ type: T.Type) throws -> T? where T.ID == EntityID {
            let key = folder + "/" + id.rawValue
            try check(!active.contains(key), "Required dependency cycle")
            if dependencies[folder]?[id.rawValue] != nil { return nil }
            let (entity, value) = try self.entity(folder, id.rawValue, type)
            active.insert(key); dependencies[folder, default: [:]][id.rawValue] = value
            return entity
        }
        func complete(_ folder: String, _ id: EntityID) { active.remove(folder + "/" + id.rawValue) }
        func scope(_ id: EntityID) throws {
            if let value = try resource("scopes", id, ArchitectureScope.self) {
                if let parent = value.parentID { try scope(parent) }; complete("scopes", id)
            }
        }
        func token(_ id: EntityID) throws {
            if let value = try resource("tokens", id, DesignToken.self) {
                try scope(value.ownerScopeID)
                if case .reference(let next) = value.value { try token(next) }; complete("tokens", id)
            }
        }
        func asset(_ id: EntityID) throws {
            if let value = try resource("assets", id, Asset.self) { try scope(value.ownerScopeID); complete("assets", id) }
        }
        func motion(_ id: EntityID) throws {
            if let _ = try resource("motions", id, Motion.self) { complete("motions", id) }
        }
        func interaction(_ id: EntityID) throws {
            if let value = try resource("interactions", id, Interaction.self) {
                for transition in value.transitions { if let id = transition.motionID { try motion(id) } }; complete("interactions", id)
            }
        }
        func component(_ id: EntityID) throws {
            if let value = try resource("components", id, ComponentDefinition.self) {
                try scope(value.ownerScopeID)
                for id in value.availability.denyScopeIDs + value.availability.allowOnlyScopeIDs { try scope(id) }
                try layers(value.root); complete("components", id)
            }
        }
        func layers(_ root: Layer) throws {
            for layer in walk(root) {
                if let id = layer.layout.spacingTokenID { try token(id) }
                for effect in layer.effects { try token(effect.tokenID) }
                if let id = layer.assetID { try asset(id) }
                if let id = layer.component?.definitionID { try component(id) }
                if let id = layer.interactionID { try interaction(id) }
            }
        }
        try scope(typed(context["scopeID"]!, EntityID.self)); try layers(layer)
        let projection = try projectionValue(header, context: context, layer: layer, screen: screen, dependencies: dependencies, task: task)
        let (bytes, encodeMs) = try measured { try encode(projection) }
        let total = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return (PartialSemanticSlice(bytes: bytes), ["totalMs": total, "fileReadMs": readMs, "jsonAndTypedDecodeMs": decodeMs,
            "closureAndSelectionMs": max(0, total - readMs - decodeMs - encodeMs), "projectionEncodeMs": encodeMs,
            "pathsRead": paths, "filesRead": paths.count, "bytesRead": sizes.values.reduce(0, +), "largestFileRead": sizes.values.max() ?? 0,
            "dependencyIDs": dependencies.mapValues { $0.keys.sorted() }])
    }
}
func projectionValue(_ header: TestManifest, context: [String: Any], layer: Layer, screen: Screen?, dependencies: [String: [String: [String: Any]]], task: String) throws -> [String: Any] {
    var result: [String: Any] = ["task": task, "documentID": try asObject(header.id), "documentRevision": header.revision,
        "authoringHarness": try asObject(header.authoringHarness), "screenContext": context,
        "payload": try screen.map(asObject) ?? asObject(layer), "globalValidityProven": false, "authoringReady": false]
    for folder in ["scopes", "components", "tokens", "assets", "interactions", "motions"] {
        result[folder] = dependencies[folder, default: [:]].keys.sorted().map { dependencies[folder]![$0]! }
    }
    return result
}
// Independent full oracle closure: queue over fully validated typed entities,
// rather than recursive filesystem retrieval. Never called by SliceReader.
func oracle(_ doc: Document, manifest: [String: Any], spec: PartialSpec, task: String) throws -> Data {
    guard let screen = doc.screens.first(where: { $0.id.rawValue == spec.screenID }) else { throw ProbeError("Oracle screen missing") }
    let root: Layer
    if task == "A" { guard let selected = screen.root.children.first(where: { $0.id.rawValue == spec.subtreeID }) else { throw ProbeError("Oracle subtree missing") }; root = selected }
    else if task == "C" { guard let selected = walk(screen.root).first(where: { $0.id.rawValue == spec.layerID }) else { throw ProbeError("Oracle layer missing") }; root = selected }
    else { root = screen.root }
    var queue: [(String, EntityID)] = [("scopes", screen.scopeID)], visited: Set<String> = []
    var dependencies: [String: [String: [String: Any]]] = [:]
    func enqueueLayers(_ root: Layer) {
        for layer in walk(root) {
            queue += ([layer.layout.spacingTokenID].compactMap { $0 } + layer.effects.map(\.tokenID)).map { ("tokens", $0) }
            if let id = layer.assetID { queue.append(("assets", id)) }
            if let id = layer.component?.definitionID { queue.append(("components", id)) }
            if let id = layer.interactionID { queue.append(("interactions", id)) }
        }
    }
    enqueueLayers(root)
    var cursor = 0
    while cursor < queue.count {
        let (folder, id) = queue[cursor]; cursor += 1
        if !visited.insert(folder + "/" + id.rawValue).inserted { continue }
        let value: [String: Any]
        switch folder {
        case "scopes":
            guard let item = doc.scopes.first(where: { $0.id == id }) else { throw ProbeError("Oracle Scope missing") }
            value = try asObject(item); if let parent = item.parentID { queue.append(("scopes", parent)) }
        case "tokens":
            guard let item = doc.tokens.first(where: { $0.id == id }) else { throw ProbeError("Oracle Token missing") }
            value = try asObject(item); queue.append(("scopes", item.ownerScopeID))
            if case .reference(let next) = item.value { queue.append(("tokens", next)) }
        case "assets":
            guard let item = doc.assets.first(where: { $0.id == id }) else { throw ProbeError("Oracle Asset missing") }
            value = try asObject(item); queue.append(("scopes", item.ownerScopeID))
        case "components":
            guard let item = doc.components.first(where: { $0.id == id }) else { throw ProbeError("Oracle Component missing") }
            value = try asObject(item); queue += ([item.ownerScopeID] + item.availability.denyScopeIDs + item.availability.allowOnlyScopeIDs).map { ("scopes", $0) }; enqueueLayers(item.root)
        case "interactions":
            guard let item = doc.interactions.first(where: { $0.id == id }) else { throw ProbeError("Oracle Interaction missing") }
            value = try asObject(item); queue += item.transitions.compactMap(\.motionID).map { ("motions", $0) }
        default:
            guard let item = doc.motions.first(where: { $0.id == id }) else { throw ProbeError("Oracle Motion missing") }; value = try asObject(item)
        }
        dependencies[folder, default: [:]][id.rawValue] = value
    }
    let context: [String: Any] = ["id": try asObject(screen.id), "name": screen.name, "scopeID": try asObject(screen.scopeID)]
    return try encode(projectionValue(typed(manifest, TestManifest.self), context: context, layer: root, screen: task == "B" ? screen : nil, dependencies: dependencies, task: task))
}
func benchmark(_ spec: PartialSpec, emit: ([String: Any]) throws -> Void) throws {
    let root = URL(fileURLWithPath: spec.root)
    let originalFiles = try readFiles(URL(fileURLWithPath: spec.canonical), canonical: true)
    let doc = try CanonicalRepository(root: URL(fileURLWithPath: spec.canonical)).load()
    try validate(doc)
    let inventory = try reconstructed(values(readFiles(root, canonical: false)), layout: spec.layout)
    try check(document(inventory) == doc, "Candidate differs from actual Current oracle")
    for task in ["full", "A", "B", "C"] {
        let before = try fingerprint(readFiles(root, canonical: false))
        try check(before == spec.sourceFingerprint, "Source drift before series")
        var expected: Data? = task == "full" ? nil : try oracle(doc, manifest: object(originalFiles["hamii.json"]!), spec: spec, task: task)
        var paths: [String]?, semantic: String?
        for sample in -1..<10 {
            var row: [String: Any]
            if task == "full" {
                let (result, stats) = try openPrototype(root, layout: spec.layout); try check(result == doc, "Full oracle mismatch")
                row = stats
            } else {
                let reader = SliceReader(root, spec.layout)
                let (slice, stats) = try reader.slice(spec, task: task)
                try check(slice.bytes == expected!, "Partial oracle mismatch")
                let hash = digest(slice.bytes)
                if let old = semantic { try check(old == hash && paths == reader.paths, "Nondeterministic partial output/reads") }
                else { semantic = hash; paths = reader.paths }
                if task == "A" && spec.layout == "SUBTREE-N" {
                    try check(reader.paths.filter { $0.hasPrefix("subtrees/") } == ["subtrees/\(spec.subtreeID).json"], "Hidden sibling subtree read")
                    try check(!reader.paths.contains("screens/screen_merge_B.json") && !reader.paths.contains("assets/asset_unreferenced.json"), "Hidden unrelated read")
                }
                row = stats; row["semanticOutputHash"] = hash; row["oracleOutputHash"] = digest(expected!)
                row["oracleEquivalent"] = true; row["globalValidityProven"] = slice.globalValidityProven; row["authoringReady"] = slice.authoringReady
            }
            row["task"] = task; row["sample"] = sample; row["warmup"] = sample == -1; row["status"] = "passed"
            try emit(row)
        }
        let after = try fingerprint(readFiles(root, canonical: false)); try check(after == before, "Source drift after series")
        try emit(["task": task, "seriesComplete": true, "measurementSourceFingerprint": before, "postFingerprint": after])
        expected = nil
    }
}
do {
    let args = CommandLine.arguments
    if args.count == 3 && args[1] == "serialize" {
        struct Envelope: Decodable { let files: [String: Data] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: FileHandle.standardInput.readDataToEndOfFile())
        FileHandle.standardOutput.write(try JSONEncoder().encode(["files": layoutValues(values(envelope.files), layout: args[2]).mapValues(encode)]))
    } else if args.count == 3 && (args[1] == "benchmark" || args[1] == "slice") {
        let spec = try JSONDecoder().decode(PartialSpec.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        if args[1] == "slice" {
            let reader = SliceReader(URL(fileURLWithPath: spec.root), spec.layout)
            let (slice, stats) = try reader.slice(spec, task: "A")
            var result = stats; result["semanticOutputHash"] = digest(slice.bytes); result["globalValidityProven"] = false; result["authoringReady"] = false
            FileHandle.standardOutput.write(try encode(result))
        } else {
            try benchmark(spec) { row in FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([0x0A])) }
        }
    } else { throw ProbeError("usage: serialize LAYOUT | benchmark SPEC | slice SPEC") }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
