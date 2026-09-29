import Foundation

/// Historical parsing and transformation knowledge lives only in HamiiMigrations.
/// The dictionaries remain raw until the Current Format reader validates the candidate.
enum FormatV1 {
    typealias Object = [String: Any]
    private static let folders: Set<String> = ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]
    private static let capabilityKeys: Set<String> = [
        "layout.stack.container", "layout.overlay.visual", "layout.scroll.container",
        "component.text.visual", "component.button.visual", "component.button.eventEmit",
        "component.image.visual", "component.instance.resolve", "content.fixtureBinding",
        "content.bindingFallback", "layout.spacingToken", "layout.paddingToken",
        "asset.systemMapping", "asset.repositoryRendering", "asset.remoteFetch",
        "asset.runtimeBinding", "asset.generatedRendering", "navigation.system.container",
        "navigation.system.title", "navigation.toolbar.systemOwnership", "navigation.toolbar.eventEmit",
        "navigation.custom.container", "interaction.runtime", "native.intent", "native.targetOverride",
        "layout.stack", "layout.overlay", "layout.scroll", "component.text", "component.button",
        "component.image", "component.instance", "token.spacing", "navigation.system", "navigation.custom"
    ]

    struct Manifest {
        let raw: Object
        let versions: Object
        let declarations: [Object]
        init(_ raw: Object, diagnostics: inout [MigrationDiagnostic]) throws {
            try inspect(raw, path: "hamii.json", id: nil,
                allowed: ["formatVersion", "id", "name", "revision", "versions", "authoringHarness", "capabilityDeclarations", "tokenTemplate"],
                required: ["formatVersion", "id", "name", "revision", "versions", "authoringHarness", "capabilityDeclarations"], into: &diagnostics)
            try entityID(raw["id"], path: "hamii.json.id", into: &diagnostics)
            _ = try string(raw["name"], at: "hamii.json.name")
            _ = try integer(raw["revision"], at: "hamii.json.revision")
            let versions = try object(raw["versions"], at: "hamii.json.versions")
            try inspect(versions, path: "hamii.json.versions", id: nil,
                allowed: ["document", "authoringHarness", "integrationProfile"],
                required: ["document", "authoringHarness", "integrationProfile"], into: &diagnostics)
            for key in ["document", "authoringHarness", "integrationProfile"] {
                _ = try integer(versions[key], at: "hamii.json.versions.\(key)")
            }
            let harness = try object(raw["authoringHarness"], at: "hamii.json.authoringHarness")
            try inspect(harness, path: "hamii.json.authoringHarness", id: nil,
                allowed: ["requireAccessibleControls", "requireTokenSpacing", "maximumMutationNodes"],
                required: ["requireAccessibleControls", "requireTokenSpacing", "maximumMutationNodes"], into: &diagnostics)
            _ = try boolean(harness["requireAccessibleControls"], at: "hamii.json.authoringHarness.requireAccessibleControls")
            _ = try boolean(harness["requireTokenSpacing"], at: "hamii.json.authoringHarness.requireTokenSpacing")
            _ = try integer(harness["maximumMutationNodes"], at: "hamii.json.authoringHarness.maximumMutationNodes")
            let declarations = try array(raw["capabilityDeclarations"], at: "hamii.json.capabilityDeclarations")
                .enumerated().map { index, value -> Object in
                    let path = "hamii.json.capabilityDeclarations[\(index)]"
                    let item = try object(value, at: path)
                    try inspect(item, path: path, id: nil, allowed: ["targetID", "key", "support", "reason"],
                                required: ["targetID", "key", "support", "reason"], into: &diagnostics)
                    try entityID(item["targetID"], path: "\(path).targetID", into: &diagnostics)
                    let key = try object(item["key"], at: "\(path).key")
                    try inspect(key, path: "\(path).key", id: nil, allowed: ["rawValue"], required: ["rawValue"], into: &diagnostics)
                    let name = try string(key["rawValue"], at: "\(path).key.rawValue")
                    if name == "effect.padding" {
                        diagnostics.append(MigrationDiagnostic(code: "capability.ambiguousPadding", path: path,
                            reason: "A v1 effect.padding declaration cannot be reinterpreted as the v2 effect"))
                    } else if !capabilityKeys.contains(name) {
                        diagnostics.append(MigrationDiagnostic(code: "capability.unknown", path: path,
                            reason: "Historical capability \(name) is not covered by this edge"))
                    }
                    let support = try string(item["support"], at: "\(path).support")
                    guard ["exact", "portable", "targetSpecific", "approximate", "unsupported", "externalIntegrationRequired"].contains(support) else {
                        throw MigrationEdgeFailure.invalidInput("Unknown support at \(path).support")
                    }
                    _ = try string(item["reason"], at: "\(path).reason")
                    return item
                }
            if let provenance = raw["tokenTemplate"] {
                let value = try object(provenance, at: "hamii.json.tokenTemplate")
                try inspect(value, path: "hamii.json.tokenTemplate", id: nil,
                    allowed: ["templateID", "templateVersion", "instantiatedAt"],
                    required: ["templateID", "templateVersion", "instantiatedAt"], into: &diagnostics)
                for key in ["templateID", "templateVersion", "instantiatedAt"] {
                    _ = try string(value[key], at: "hamii.json.tokenTemplate.\(key)")
                }
            }
            self.raw = raw; self.versions = versions; self.declarations = declarations
        }
    }

    struct Layer {
        let raw: Object
        let path: String
        let id: String
        init(_ raw: Object, path: String, diagnostics: inout [MigrationDiagnostic]) throws {
            let id = try entityID(raw["id"], path: "\(path).id", into: &diagnostics)
            try inspect(raw, path: path, id: id,
                allowed: ["id", "kind", "name", "children", "layout", "text", "textBinding", "emittedEvent", "assetID", "component", "interactionID", "accessibilityLabel", "nativeIntent", "targetOverrides"],
                required: ["id", "kind", "name", "children", "layout", "targetOverrides"], into: &diagnostics)
            let kind = try string(raw["kind"], at: "\(path).kind")
            guard ["stack", "overlay", "scroll", "text", "image", "button", "componentInstance"].contains(kind) else {
                diagnostics.append(MigrationDiagnostic(code: "layer.unknownKind", path: path, entityID: id, reason: "Unknown historical Layer kind \(kind)"))
                self.raw = raw; self.path = path; self.id = id; return
            }
            let ownership: [String: Set<String>] = [
                "text": ["text", "button"], "textBinding": ["text", "button"],
                "emittedEvent": ["button"], "assetID": ["image"], "component": ["componentInstance"]
            ]
            for (key, kinds) in ownership.sorted(by: { $0.key < $1.key }) where raw[key] != nil && !kinds.contains(kind) {
                diagnostics.append(MigrationDiagnostic(code: "layer.crossKindResidual", path: "\(path).\(key)",
                    entityID: id, reason: "Format v1 stored \(key) on \(kind); Current Format v2 cannot preserve it"))
            }
            _ = try string(raw["name"], at: "\(path).name")
            let layout = try object(raw["layout"], at: "\(path).layout")
            try inspect(layout, path: "\(path).layout", id: id, allowed: ["axis", "spacingTokenID", "paddingTokenID"],
                        required: [], into: &diagnostics)
            if let axis = layout["axis"] { _ = try string(axis, at: "\(path).layout.axis") }
            if let axis = layout["axis"] as? String, !["vertical", "horizontal"].contains(axis) {
                throw MigrationEdgeFailure.invalidInput("Unknown axis at \(path).layout.axis")
            }
            for key in ["spacingTokenID", "paddingTokenID"] where layout[key] != nil {
                try entityID(layout[key], path: "\(path).layout.\(key)", into: &diagnostics)
            }
            for key in ["assetID", "interactionID"] where raw[key] != nil {
                try entityID(raw[key], path: "\(path).\(key)", into: &diagnostics)
            }
            for key in ["text", "textBinding", "emittedEvent", "accessibilityLabel", "nativeIntent"] where raw[key] != nil {
                _ = try string(raw[key], at: "\(path).\(key)")
            }
            try stringMap(raw["targetOverrides"], path: "\(path).targetOverrides")
            let children = try array(raw["children"], at: "\(path).children")
            for (index, child) in children.enumerated() {
                _ = try Layer(object(child, at: "\(path).children[\(index)]"), path: "\(path).children[\(index)]", diagnostics: &diagnostics)
            }
            if let componentValue = raw["component"] {
                let componentPath = "\(path).component"
                let component = try object(componentValue, at: componentPath)
                try inspect(component, path: componentPath, id: id,
                    allowed: ["definitionID", "variantSelection", "propertyValues", "slotContent", "allowedOverrides"],
                    required: ["definitionID", "variantSelection", "propertyValues", "slotContent", "allowedOverrides"], into: &diagnostics)
                try entityID(component["definitionID"], path: "\(componentPath).definitionID", into: &diagnostics)
                try stringMap(component["variantSelection"], path: "\(componentPath).variantSelection")
                try stringMap(component["propertyValues"], path: "\(componentPath).propertyValues")
                try stringMap(component["allowedOverrides"], path: "\(componentPath).allowedOverrides")
                let slots = try object(component["slotContent"], at: "\(componentPath).slotContent")
                for (slot, values) in slots.sorted(by: { $0.key < $1.key }) {
                    for (index, child) in try array(values, at: "\(componentPath).slotContent.\(slot)").enumerated() {
                        _ = try Layer(object(child, at: "\(componentPath).slotContent.\(slot)[\(index)]"),
                            path: "\(componentPath).slotContent.\(slot)[\(index)]", diagnostics: &diagnostics)
                    }
                }
            }
            self.raw = raw; self.path = path; self.id = id
        }

        func upgraded() throws -> Object {
            var layer = raw
            var layout = try object(raw["layout"], at: "\(path).layout")
            if let padding = layout.removeValue(forKey: "paddingTokenID") {
                layer["effects"] = [["kind": "padding", "tokenID": padding]]
            } else {
                layer["effects"] = [Object]()
            }
            layer["layout"] = layout
            let children = try array(raw["children"], at: "\(path).children")
            layer["children"] = try children.enumerated().map { index, child in
                var diagnostics: [MigrationDiagnostic] = []
                return try Layer(object(child, at: "\(path).children[\(index)]"), path: "\(path).children[\(index)]", diagnostics: &diagnostics).upgraded()
            }
            if let componentRaw = raw["component"] {
                var component = try object(componentRaw, at: "\(path).component")
                let slots = try object(component["slotContent"], at: "\(path).component.slotContent")
                var upgradedSlots: Object = [:]
                for (slot, values) in slots {
                    upgradedSlots[slot] = try array(values, at: "\(path).component.slotContent.\(slot)").enumerated().map { index, child in
                        var diagnostics: [MigrationDiagnostic] = []
                        return try Layer(object(child, at: "\(path).component.slotContent.\(slot)[\(index)]"),
                                         path: "\(path).component.slotContent.\(slot)[\(index)]", diagnostics: &diagnostics).upgraded()
                    }
                }
                component["slotContent"] = upgradedSlots
                layer["component"] = component
            }
            return layer
        }
    }

    static func markers(in files: [String: Data]) throws -> Int {
        guard let bytes = files["hamii.json"] else { throw MigrationEdgeFailure.invalidInput("hamii.json is missing") }
        let manifest = try object(bytes, at: "hamii.json")
        let format = try integer(manifest["formatVersion"], at: "hamii.json.formatVersion")
        let versions = try object(manifest["versions"], at: "hamii.json.versions")
        let document = try integer(versions["document"], at: "hamii.json.versions.document")
        guard format == document else { throw MigrationEdgeFailure.invalidInput("Document format markers disagree: \(format)/\(document)") }
        return format
    }

    static func analyze(_ files: [String: Data]) throws -> [MigrationDiagnostic] {
        guard try markers(in: files) == 1 else { throw MigrationEdgeFailure.invalidInput("Expected Format v1") }
        var diagnostics: [MigrationDiagnostic] = []
        let manifest = try Manifest(object(files["hamii.json"], at: "hamii.json"), diagnostics: &diagnostics)
        var padded = false
        for path in files.keys.sorted() where path != "hamii.json" && path != "hamii-agent-profiles.json" {
            if path.hasPrefix("assets/blobs/") { continue }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2, folders.contains(parts[0]), parts[1].hasSuffix(".json") else {
                diagnostics.append(MigrationDiagnostic(code: "path.unknown", path: path, reason: "Path is outside the known Canonical file set"))
                continue
            }
            let value = try object(files[path], at: path)
            try inspectEntity(value, folder: parts[0], path: path, diagnostics: &diagnostics)
            if parts[0] == "screens" || parts[0] == "components" {
                padded = padded || containsPadding(value["root"])
            }
        }
        if padded {
            let grouped = Dictionary(grouping: manifest.declarations.filter { declaration in
                ((declaration["key"] as? Object)?["rawValue"] as? String) == "token.spacing"
            }, by: { (($0["targetID"] as? Object)?["rawValue"] as? String) ?? "" })
            for (target, declarations) in grouped where declarations.count > 1 {
                diagnostics.append(MigrationDiagnostic(code: "capability.ambiguousSpacing", path: "hamii.json.capabilityDeclarations",
                    entityID: target, reason: "Multiple token.spacing declarations cannot select one effect.padding declaration"))
            }
        }
        return diagnostics.sorted { ($0.path, $0.code, $0.entityID ?? "") < ($1.path, $1.code, $1.entityID ?? "") }
    }

    static func upgrade(_ files: [String: Data]) throws -> [String: Data] {
        guard try markers(in: files) == 1 else { throw MigrationEdgeFailure.invalidInput("Expected Format v1") }
        var candidate = files
        var manifest = try object(files["hamii.json"], at: "hamii.json")
        var versions = try object(manifest["versions"], at: "hamii.json.versions")
        versions["document"] = 2
        manifest["versions"] = versions
        manifest["formatVersion"] = 2
        let padded = files.keys.contains { path in
            guard path.hasPrefix("screens/") || path.hasPrefix("components/"), let bytes = files[path],
                  let entity = try? object(bytes, at: path) else { return false }
            return containsPadding(entity["root"])
        }
        if padded {
            let declarations = try array(manifest["capabilityDeclarations"], at: "hamii.json.capabilityDeclarations")
            var result = declarations
            for entry in declarations {
                let declaration = try object(entry, at: "hamii.json.capabilityDeclarations")
                let key = try object(declaration["key"], at: "hamii.json.capabilityDeclarations.key")
                if key["rawValue"] as? String == "token.spacing" {
                    var added = declaration
                    added["key"] = ["rawValue": "effect.padding"]
                    result.append(added)
                }
            }
            manifest["capabilityDeclarations"] = result
        }
        candidate["hamii.json"] = try encoded(manifest)
        for path in files.keys.sorted() where path.hasPrefix("screens/") || path.hasPrefix("components/") {
            guard path.hasSuffix(".json") else { continue }
            var entity = try object(files[path], at: path)
            let root = try object(entity["root"], at: "\(path).root")
            var ignored: [MigrationDiagnostic] = []
            entity["root"] = try Layer(root, path: "\(path).root", diagnostics: &ignored).upgraded()
            candidate[path] = try encoded(entity)
        }
        return candidate
    }

    private static func containsPadding(_ value: Any?) -> Bool {
        guard let layer = value as? Object else { return false }
        if (layer["layout"] as? Object)?["paddingTokenID"] != nil { return true }
        if (layer["children"] as? [Any])?.contains(where: { containsPadding($0) }) == true { return true }
        if let slots = (layer["component"] as? Object)?["slotContent"] as? Object {
            for values in slots.values where (values as? [Any])?.contains(where: { containsPadding($0) }) == true { return true }
        }
        return false
    }

    private static func encoded(_ value: Object) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        bytes.append(0x0A)
        return bytes
    }

    private static func object(_ bytes: Data?, at path: String) throws -> Object {
        guard let bytes else { throw MigrationEdgeFailure.invalidInput("Missing \(path)") }
        return try object(JSONSerialization.jsonObject(with: bytes), at: path)
    }
    private static func object(_ value: Any?, at path: String) throws -> Object {
        guard let value = value as? Object else { throw MigrationEdgeFailure.invalidInput("Expected object at \(path)") }
        return value
    }
    private static func array(_ value: Any?, at path: String) throws -> [Any] {
        guard let value = value as? [Any] else { throw MigrationEdgeFailure.invalidInput("Expected array at \(path)") }
        return value
    }
    private static func string(_ value: Any?, at path: String) throws -> String {
        guard let value = value as? String else { throw MigrationEdgeFailure.invalidInput("Expected string at \(path)") }
        return value
    }
    private static func integer(_ value: Any?, at path: String) throws -> Int {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
              number.doubleValue == Double(number.intValue) else {
            throw MigrationEdgeFailure.invalidInput("Expected integer at \(path)")
        }
        return number.intValue
    }
    private static func boolean(_ value: Any?, at path: String) throws -> Bool {
        guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else {
            throw MigrationEdgeFailure.invalidInput("Expected boolean at \(path)")
        }
        return number.boolValue
    }
    @discardableResult private static func entityID(_ value: Any?, path: String,
                                                     into diagnostics: inout [MigrationDiagnostic]) throws -> String {
        let object = try object(value, at: path)
        try inspect(object, path: path, id: nil, allowed: ["rawValue"], required: ["rawValue"], into: &diagnostics)
        let id = try string(object["rawValue"], at: "\(path).rawValue")
        guard !id.isEmpty else { throw MigrationEdgeFailure.invalidInput("Empty stable ID at \(path)") }
        return id
    }
    private static func stringMap(_ value: Any?, path: String) throws {
        let map = try object(value, at: path)
        for (key, value) in map { _ = try string(value, at: "\(path).\(key)") }
    }
    private static func stringArray(_ value: Any?, path: String) throws {
        for (index, item) in try array(value, at: path).enumerated() {
            _ = try string(item, at: "\(path)[\(index)]")
        }
    }
    private static func knownValue(_ value: Any?, at path: String, among values: Set<String>) throws {
        let name = try string(value, at: path)
        guard values.contains(name) else { throw MigrationEdgeFailure.invalidInput("Unknown historical value at \(path): \(name)") }
    }
    private static func inspect(_ value: Object, path: String, id: String?, allowed: Set<String>,
                                required: Set<String>, into diagnostics: inout [MigrationDiagnostic]) throws {
        for key in required where value[key] == nil { throw MigrationEdgeFailure.invalidInput("Missing \(path).\(key)") }
        for key in value.keys.sorted() where !allowed.contains(key) {
            diagnostics.append(MigrationDiagnostic(code: "schema.unknownField", path: "\(path).\(key)", entityID: id,
                reason: "Historical field is not covered by the v1→v2 edge"))
        }
    }

    private static func inspectEntity(_ value: Object, folder: String, path: String,
                                      diagnostics: inout [MigrationDiagnostic]) throws {
        switch folder {
        case "screens":
            try inspect(value, path: path, id: nil, allowed: ["id", "name", "scopeID", "root", "navigation"],
                        required: ["id", "name", "scopeID", "root"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            try entityID(value["scopeID"], path: "\(path).scopeID", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            _ = try Layer(object(value["root"], at: "\(path).root"), path: "\(path).root", diagnostics: &diagnostics)
            if let navigation = value["navigation"] { try inspectNavigation(navigation, path: "\(path).navigation", diagnostics: &diagnostics) }
        case "components":
            try inspect(value, path: path, id: nil,
                allowed: ["id", "name", "ownerScopeID", "visibility", "availability", "api", "variants", "root", "nativeSemantics"],
                required: ["id", "name", "ownerScopeID", "visibility", "availability", "api", "variants", "root", "nativeSemantics"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            try entityID(value["ownerScopeID"], path: "\(path).ownerScopeID", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            _ = try string(value["visibility"], at: "\(path).visibility")
            let availability = try object(value["availability"], at: "\(path).availability")
            try inspect(availability, path: "\(path).availability", id: nil,
                allowed: ["denyScopeIDs", "allowOnlyScopeIDs"], required: ["denyScopeIDs", "allowOnlyScopeIDs"], into: &diagnostics)
            for key in ["denyScopeIDs", "allowOnlyScopeIDs"] {
                for (index, id) in try array(availability[key], at: "\(path).availability.\(key)").enumerated() {
                    try entityID(id, path: "\(path).availability.\(key)[\(index)]", into: &diagnostics)
                }
            }
            let api = try object(value["api"], at: "\(path).api")
            try inspect(api, path: "\(path).api", id: nil,
                allowed: ["properties", "slots", "bindings", "events", "overridablePaths"],
                required: ["properties", "slots", "bindings", "events", "overridablePaths"], into: &diagnostics)
            for key in ["bindings", "events", "overridablePaths"] {
                try stringArray(api[key], path: "\(path).api.\(key)")
            }
            for (index, item) in try array(api["properties"], at: "\(path).api.properties").enumerated() {
                let field = try object(item, at: "\(path).api.properties[\(index)]")
                try inspect(field, path: "\(path).api.properties[\(index)]", id: nil,
                            allowed: ["name", "kind", "targetPath"], required: ["name", "kind", "targetPath"], into: &diagnostics)
                _ = try string(field["name"], at: "\(path).api.properties[\(index)].name")
                _ = try string(field["targetPath"], at: "\(path).api.properties[\(index)].targetPath")
                try knownValue(field["kind"], at: "\(path).api.properties[\(index)].kind",
                               among: ["text", "number", "boolean", "asset", "token"])
            }
            for (index, item) in try array(api["slots"], at: "\(path).api.slots").enumerated() {
                let slot = try object(item, at: "\(path).api.slots[\(index)]")
                try inspect(slot, path: "\(path).api.slots[\(index)]", id: nil,
                            allowed: ["name", "targetLayerID"], required: ["name", "targetLayerID"], into: &diagnostics)
                try entityID(slot["targetLayerID"], path: "\(path).api.slots[\(index)].targetLayerID", into: &diagnostics)
                _ = try string(slot["name"], at: "\(path).api.slots[\(index)].name")
            }
            for (index, item) in try array(value["variants"], at: "\(path).variants").enumerated() {
                let variant = try object(item, at: "\(path).variants[\(index)]")
                try inspect(variant, path: "\(path).variants[\(index)]", id: nil,
                    allowed: ["id", "axis", "value", "propertyOverrides"],
                    required: ["id", "axis", "value", "propertyOverrides"], into: &diagnostics)
                try entityID(variant["id"], path: "\(path).variants[\(index)].id", into: &diagnostics)
                _ = try string(variant["axis"], at: "\(path).variants[\(index)].axis")
                _ = try string(variant["value"], at: "\(path).variants[\(index)].value")
                try stringMap(variant["propertyOverrides"], path: "\(path).variants[\(index)].propertyOverrides")
            }
            try stringMap(value["nativeSemantics"], path: "\(path).nativeSemantics")
            _ = try Layer(object(value["root"], at: "\(path).root"), path: "\(path).root", diagnostics: &diagnostics)
        case "pages":
            try inspect(value, path: path, id: nil, allowed: ["id", "name", "surfaces"], required: ["id", "name", "surfaces"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            for (index, item) in try array(value["surfaces"], at: "\(path).surfaces").enumerated() {
                let surface = try object(item, at: "\(path).surfaces[\(index)]")
                try inspect(surface, path: "\(path).surfaces[\(index)]", id: nil,
                    allowed: ["id", "targetID", "device", "runtime", "buildEnvironment", "environment", "screenID", "fixtureID", "architectureScopeID", "previewConfiguration"],
                    required: ["id", "targetID", "device", "runtime", "buildEnvironment", "environment", "screenID", "architectureScopeID", "previewConfiguration"], into: &diagnostics)
                for key in ["id", "targetID", "screenID", "architectureScopeID", "fixtureID"] where surface[key] != nil {
                    try entityID(surface[key], path: "\(path).surfaces[\(index)].\(key)", into: &diagnostics)
                }
                for key in ["device", "runtime", "buildEnvironment"] {
                    _ = try string(surface[key], at: "\(path).surfaces[\(index)].\(key)")
                }
                try stringMap(surface["environment"], path: "\(path).surfaces[\(index)].environment")
                try stringMap(surface["previewConfiguration"], path: "\(path).surfaces[\(index)].previewConfiguration")
            }
        case "scopes":
            try inspect(value, path: path, id: nil, allowed: ["id", "name", "parentID"], required: ["id", "name"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            if let parent = value["parentID"] { try entityID(parent, path: "\(path).parentID", into: &diagnostics) }
        case "tokens":
            try inspect(value, path: path, id: nil, allowed: ["id", "name", "kind", "ownerScopeID", "value"],
                        required: ["id", "name", "kind", "ownerScopeID", "value"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            try entityID(value["ownerScopeID"], path: "\(path).ownerScopeID", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            try knownValue(value["kind"], at: "\(path).kind",
                           among: ["color", "typography", "spacing", "radius", "border", "shadow", "opacity", "motion"])
            let tagged = try object(value["value"], at: "\(path).value")
            try inspectTag(tagged, path: "\(path).value", allowed: ["literal": ["_0"], "reference": ["_0"]], diagnostics: &diagnostics)
            if let payload = tagged["literal"] as? Object {
                _ = try string(payload["_0"], at: "\(path).value.literal._0")
            }
            if let payload = tagged["reference"] as? Object {
                try entityID(payload["_0"], path: "\(path).value.reference._0", into: &diagnostics)
            }
        case "assets":
            try inspect(value, path: path, id: nil,
                allowed: ["id", "name", "ownerScopeID", "mediaType", "source", "contentHash", "metadata"],
                required: ["id", "name", "ownerScopeID", "mediaType", "source", "metadata"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            try entityID(value["ownerScopeID"], path: "\(path).ownerScopeID", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            _ = try string(value["mediaType"], at: "\(path).mediaType")
            if let hash = value["contentHash"] { _ = try string(hash, at: "\(path).contentHash") }
            let tagged = try object(value["source"], at: "\(path).source")
            try inspectTag(tagged, path: "\(path).source", allowed: ["repository": ["path"], "remote": ["url"], "runtime": ["binding"], "system": ["name"], "generated": ["path", "provenance"]], diagnostics: &diagnostics)
            for (kind, keys) in ["repository": ["path"], "remote": ["url"], "runtime": ["binding"], "system": ["name"], "generated": ["path", "provenance"]] {
                if let payload = tagged[kind] as? Object {
                    for key in keys { _ = try string(payload[key], at: "\(path).source.\(kind).\(key)") }
                }
            }
            try stringMap(value["metadata"], path: "\(path).metadata")
        case "interactions":
            try inspect(value, path: path, id: nil, allowed: ["id", "name", "states", "transitions"],
                        required: ["id", "name", "states", "transitions"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            try stringArray(value["states"], path: "\(path).states")
            for (index, item) in try array(value["transitions"], at: "\(path).transitions").enumerated() {
                let transition = try object(item, at: "\(path).transitions[\(index)]")
                try inspect(transition, path: "\(path).transitions[\(index)]", id: nil,
                    allowed: ["from", "event", "to", "motionID", "actions"], required: ["from", "event", "to", "actions"], into: &diagnostics)
                if let motion = transition["motionID"] { try entityID(motion, path: "\(path).transitions[\(index)].motionID", into: &diagnostics) }
                for key in ["from", "event", "to"] {
                    _ = try string(transition[key], at: "\(path).transitions[\(index)].\(key)")
                }
                for (actionIndex, action) in try array(transition["actions"], at: "\(path).transitions[\(index)].actions").enumerated() {
                    let tagged = try object(action, at: "\(path).transitions[\(index)].actions[\(actionIndex)]")
                    try inspectTag(tagged, path: "\(path).transitions[\(index)].actions[\(actionIndex)]",
                        allowed: ["emitEvent": ["_0"], "setValue": ["binding", "value"], "navigate": ["destination"],
                                  "present": ["destination"], "dismiss": [], "openURL": ["_0"]], diagnostics: &diagnostics)
                    for (kind, keys) in ["emitEvent": ["_0"], "setValue": ["binding", "value"],
                                          "navigate": ["destination"], "present": ["destination"], "openURL": ["_0"]] {
                        if let payload = tagged[kind] as? Object {
                            for key in keys { _ = try string(payload[key], at: "\(path).transitions[\(index)].actions[\(actionIndex)].\(kind).\(key)") }
                        }
                    }
                }
            }
        case "motions":
            try inspect(value, path: path, id: nil, allowed: ["id", "name", "kind", "parameters"],
                        required: ["id", "name", "kind", "parameters"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            _ = try string(value["kind"], at: "\(path).kind")
            try stringMap(value["parameters"], path: "\(path).parameters")
        case "fixtures":
            try inspect(value, path: path, id: nil, allowed: ["id", "name", "values", "assetBindings"],
                        required: ["id", "name", "values", "assetBindings"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            _ = try string(value["name"], at: "\(path).name")
            try stringMap(value["values"], path: "\(path).values")
            let bindings = try object(value["assetBindings"], at: "\(path).assetBindings")
            for (key, binding) in bindings { try entityID(binding, path: "\(path).assetBindings.\(key)", into: &diagnostics) }
        case "targets":
            try inspect(value, path: path, id: nil, allowed: ["id", "platform", "framework"],
                        required: ["id", "platform", "framework"], into: &diagnostics)
            try entityID(value["id"], path: "\(path).id", into: &diagnostics)
            try knownValue(value["platform"], at: "\(path).platform", among: ["iOS", "macOS", "android"])
            try knownValue(value["framework"], at: "\(path).framework",
                           among: ["swiftUI", "uiKit", "jetpackCompose", "composeMultiplatform"])
        default: break
        }
    }

    private static func inspectNavigation(_ value: Any, path: String,
                                          diagnostics: inout [MigrationDiagnostic]) throws {
        let tagged = try object(value, at: path)
        try inspectTag(tagged, path: path, allowed: ["system": ["_0"], "custom": ["layerID"]], diagnostics: &diagnostics)
        if let system = tagged["system"] as? Object, let detail = system["_0"] {
            let config = try object(detail, at: "\(path).system._0")
            try inspect(config, path: "\(path).system._0", id: nil, allowed: ["title", "toolbarItems"],
                        required: ["toolbarItems"], into: &diagnostics)
            for (index, item) in try array(config["toolbarItems"], at: "\(path).system._0.toolbarItems").enumerated() {
                let toolbar = try object(item, at: "\(path).system._0.toolbarItems[\(index)]")
                try inspect(toolbar, path: "\(path).system._0.toolbarItems[\(index)]", id: nil,
                            allowed: ["id", "title", "emittedEvent"], required: ["id", "title", "emittedEvent"], into: &diagnostics)
                try entityID(toolbar["id"], path: "\(path).system._0.toolbarItems[\(index)].id", into: &diagnostics)
            }
        }
    }

    private static func inspectTag(_ tagged: Object, path: String, allowed: [String: Set<String>],
                                   diagnostics: inout [MigrationDiagnostic]) throws {
        guard tagged.count == 1, let (name, payload) = tagged.first else {
            throw MigrationEdgeFailure.invalidInput("Expected one tagged case at \(path)")
        }
        guard let keys = allowed[name] else {
            diagnostics.append(MigrationDiagnostic(code: "schema.unknownCase", path: path,
                reason: "Historical tagged case \(name) is not covered by this edge"))
            return
        }
        let object = try object(payload, at: "\(path).\(name)")
        try inspect(object, path: "\(path).\(name)", id: nil, allowed: keys, required: keys, into: &diagnostics)
    }
}
