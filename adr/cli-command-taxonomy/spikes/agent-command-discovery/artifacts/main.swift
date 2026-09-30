import Foundation
import HamiiCore
import HamiiApplication
import HamiiFormat
import HamiiGeneration

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let manifestURL = URL(fileURLWithPath: CommandLine.arguments[2])
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
let spec = manifest["fixture"] as! [String: Any]
let ids = spec["ids"] as! [String: String]
func id(_ key: String) -> EntityID { EntityID(ids[key]!) }
let repository = CanonicalRepository(root: root)
_ = try repository.create(name: spec["name"] as! String)
let old = try repository.observe()
var document = old.document
document.id = id("document")
document.revision += 1
document.scopes = [
    ArchitectureScope(id: id("appScope"), name: "App", parentID: nil),
    ArchitectureScope(id: id("commerceScope"), name: "Commerce", parentID: id("appScope")),
    ArchitectureScope(id: id("checkoutScope"), name: "Checkout", parentID: id("commerceScope")),
    ArchitectureScope(id: id("accountScope"), name: "Account", parentID: id("appScope"))
]
let treeSpec = spec["screenTree"] as! [String: Any]
var layout = Layout(); layout.axis = .vertical
if treeSpec["spacingTokenID"] != nil { layout.spacingTokenID = id("token") }
let text = Layer(id: id("text"), name: "Summary", payload: .text(TextLayerPayload(value: "Order summary")))
let tree = Layer(id: id("root"), name: "Root", payload: .stack, children: [text], layout: layout)
let screen = Screen(id: id("screen"), name: "Checkout fixture", scopeID: id("checkoutScope"), root: tree)
document.screens = [screen]
document.components = [
    ComponentDefinition(id: id("priceBadge"), name: "PriceBadge", ownerScopeID: id("commerceScope"),
      root: Layer(id: id("priceRoot"), name: "Price", payload: .text(TextLayerPayload(value: "Price")))),
    ComponentDefinition(id: id("privateBadge"), name: "PrivateBadge", ownerScopeID: id("accountScope"),
      root: Layer(id: id("privateRoot"), name: "Private", payload: .text(TextLayerPayload(value: "Private"))))
]
document.tokens = [DesignToken(id: id("token"), name: "spacing.checkout", kind: .spacing,
    ownerScopeID: id("checkoutScope"), value: .literal("12"))]
let target = Target(id: id("target"), platform: .macOS, framework: .swiftUI)
document.targets = [target]
let targetSpec = spec["target"] as! [String: String]
let surface = AppSurface(id: id("surface"), targetID: target.id, device: targetSpec["device"]!,
    runtime: targetSpec["runtime"]!, buildEnvironment: targetSpec["buildEnvironment"]!,
    screenID: screen.id, architectureScopeID: screen.scopeID)
document.pages = [Page(id: id("page"), name: "Preview", surfaces: [surface])]
document.capabilityDeclarations = (spec["capabilities"] as! [String]).map {
    CapabilityDeclaration(targetID: target.id, key: CapabilityKey($0), support: .exact)
}
let result = try repository.commit(document, expected: old)
guard result.document == document else { fatalError("Fixture commit did not roundtrip") }
let plan = TargetPlanner.plan(surface: surface, document: try repository.load())
guard plan.canPreview else { fatalError("Fixture preview plan unsupported") }
let source = try SwiftUIGenerator.generate(document: repository.load(), screenID: screen.id, targetID: target.id)
guard !source.source.isEmpty else { fatalError("Fixture generated source empty") }
print("Fixture validated; preview and generator supported")
