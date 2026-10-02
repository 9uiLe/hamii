import Foundation
import HamiiCore
import HamiiApplication
import HamiiFormat

// Evidence-only probe of the current resolver. There is no production cache.
let instanceCount = 1000
let trialCount = 40
let definitionID = EntityID("component_card")
let titleID = EntityID("definition_title")
let detailID = EntityID("definition_detail")
var definitionChildren = [
    Layer(id: titleID, kind: .text, name: "Title", text: "Default"),
    Layer(id: detailID, kind: .text, name: "Detail", text: "Stable")
]
for index in 0..<4 {
    definitionChildren.append(Layer(id: EntityID("definition_extra_\(index)"),
        kind: .text, name: "Extra \(index)", text: "Shared \(index)"))
}
var definition = ComponentDefinition(id: definitionID, name: "Card",
    ownerScopeID: EntityID("scope_app"),
    root: Layer(id: EntityID("definition_root"), kind: .stack,
        name: "Root", children: definitionChildren, layout: Layout(axis: .vertical)))
definition.api.properties = [ComponentProperty(name: "title", kind: .text,
    targetPath: "definition_title.text")]
definition.variants = [ComponentVariant(id: EntityID("variant_large"),
    axis: "size", value: "large", propertyOverrides: ["definition_title.text": "Large"])]

var instances: [ComponentInstance] = []
var instanceLayers: [Layer] = []
for index in 0..<instanceCount {
    let instance = ComponentInstance(definitionID: definitionID,
        variantSelection: ["size": "large"], propertyValues: ["title": "Card \(index)"])
    instances.append(instance)
    instanceLayers.append(Layer(id: EntityID("instance_\(index)"),
        kind: .componentInstance, name: "Card \(index)", component: instance))
}

var document = Document(name: "Component Scale")
document.scopes = [ArchitectureScope(id: EntityID("scope_app"), name: "App", parentID: nil)]
document.components = [definition]
document.screens = [Screen(id: EntityID("screen_scale"), name: "Scale",
    scopeID: EntityID("scope_app"), root: Layer(id: EntityID("screen_root"),
        kind: .stack, name: "Root", children: instanceLayers, layout: Layout(axis: .vertical)))]

// A real Current Canonical save gives storage bytes for the sparse model.
let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("hamii-component-scale-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: scratch) }
let repository = CanonicalRepository(root: scratch)
_ = try repository.create(name: "Component Scale")
let observation = try repository.observe()
document.id = observation.document.id
document.revision = observation.document.revision + 1
let saved = try repository.commit(document, expected: observation)
precondition(saved.document.screens[0].root.children.count == instanceCount)

var canonicalFiles: [String: Int] = [:]
let normalizedRoot = scratch.resolvingSymlinksInPath().path
if let enumerator = FileManager.default.enumerator(at: scratch,
    includingPropertiesForKeys: [.isRegularFileKey]) {
    for case let url as URL in enumerator where url.pathExtension == "json" {
        let path = url.resolvingSymlinksInPath().path
        precondition(path.hasPrefix(normalizedRoot + "/"))
        let relative = String(path.dropFirst(normalizedRoot.count + 1))
        if relative.hasPrefix(".hamii/") { continue }
        canonicalFiles[relative] = try Data(contentsOf: url).count
    }
}
let sparseTotalBytes = canonicalFiles.values.reduce(0, +)
guard let sparseScreenBytes = canonicalFiles["screens/screen_scale.json"] else {
    let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
    fatalError("missing screen shard; root=\(scratch.path) entries=\(entries) captured=\(canonicalFiles.keys.sorted())")
}

func resolveAll(_ values: [ComponentInstance], definition: ComponentDefinition) throws -> [Layer] {
    try values.map { try ComponentResolver.resolve($0, definition: definition) }
}
let baseline = try resolveAll(instances, definition: definition)
precondition(baseline.count == instanceCount)
precondition(baseline[0].children.first?.text == "Card 0")

var changedInstance = instances
changedInstance[500].propertyValues["title"] = "Changed only 500"
let afterInstanceChange = try resolveAll(changedInstance, definition: definition)
let instanceAffected = baseline.indices.filter { baseline[$0] != afterInstanceChange[$0] }
var changedDefinition = definition
changedDefinition.root.children[1].text = "Changed definition detail"
let afterDefinitionChange = try resolveAll(instances, definition: changedDefinition)
let definitionAffected = baseline.indices.filter { baseline[$0] != afterDefinitionChange[$0] }

func namespaced(_ layer: Layer, prefix: String) -> Layer {
    var result = layer
    result.id = EntityID("\(prefix)_\(layer.id.rawValue)")
    result.children = layer.children.map { namespaced($0, prefix: prefix) }
    return result
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
let materialized = baseline.enumerated().map { index, layer in
    namespaced(layer, prefix: "instance_\(index)")
}
let materializedSubtreeBytes = try materialized.reduce(0) { total, layer in
    total + (try encoder.encode(layer).count) + 1 // newline, like Canonical shards
}
var materializedScreen = document.screens[0]
materializedScreen.root.children = materialized
let materializedScreenBytes = try encoder.encode(materializedScreen).count + 1

func milliseconds(_ operation: () throws -> Int) throws -> Double {
    let started = DispatchTime.now().uptimeNanoseconds
    let checksum = try operation()
    precondition(checksum > 0)
    return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
}

for _ in 0..<5 {
    _ = try ComponentResolver.resolve(instances[500], definition: definition)
    _ = try resolveAll(instances, definition: definition)
}
var oneTimes: [Double] = []
var allTimes: [Double] = []
for _ in 0..<trialCount {
    oneTimes.append(try milliseconds {
        let layer = try ComponentResolver.resolve(instances[500], definition: definition)
        return layer.children.count
    })
    allTimes.append(try milliseconds {
        try resolveAll(instances, definition: definition).count
    })
}

let result: [String: Any] = [
    "fixture": [
        "instanceCount": instanceCount,
        "definitionLayerCount": 7,
        "variantAxesSelected": 1,
        "propertiesPerInstance": 1,
        "canonicalValidationDiagnostics": DocumentValidator.validate(document).map(\.rule)
    ],
    "storageBytes": [
        "sparseCanonicalTotal": sparseTotalBytes,
        "sparseCanonicalScreenShard": sparseScreenBytes,
        "sparseCanonicalComponentShard": canonicalFiles["components/component_card.json"]!,
        "canonicalFileBytes": canonicalFiles,
        "testOnlyMaterializedResolvedSubtreeJSON": materializedSubtreeBytes,
        "testOnlyMaterializedScreenShardJSON": materializedScreenBytes
    ],
    "logicalAffectedOutputIndices": [
        "singleInstancePropertyChange": instanceAffected,
        "definitionDetailChange": definitionAffected
    ],
    "measurements": [
        "trialsPerCase": trialCount,
        "warmupsPerCase": 5,
        "oneInstanceResolveMs": oneTimes,
        "all1000ResolveMs": allTimes
    ]
]
let output = try JSONSerialization.data(withJSONObject: result,
    options: [.prettyPrinted, .sortedKeys])
print(String(decoding: output, as: UTF8.self))
