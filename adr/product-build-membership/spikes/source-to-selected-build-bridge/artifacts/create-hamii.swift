import Foundation
import HamiiCore
import HamiiFormat

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: create-hamii PATH")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let repository = CanonicalRepository(root: root)
_ = try repository.create(name: "Bridge Probe")
let observed = try repository.observe()
var document = observed.document
let scope = EntityID("scope_bridge")
let screenID = EntityID("screen_bridge")
let textID = EntityID("layer_probe")
document.scopes = [ArchitectureScope(id: scope, name: "Bridge", parentID: nil)]
var text = Layer(id: textID, kind: .text, name: "Flow spacing", text: "Spacing")
text.textBinding = "probe.flowSpacing"
document.screens = [Screen(id: screenID, name: "Bridge", scopeID: scope,
    root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: [text]))]
document.revision += 1
_ = try repository.commit(document, expected: observed)
print("screenID=\(screenID.rawValue)")
