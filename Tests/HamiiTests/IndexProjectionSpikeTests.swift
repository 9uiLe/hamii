import Foundation
import XCTest
import HamiiCore
import HamiiFormat
@testable import HamiiIndex

/// Focused evidence for the open Index consistency ADR. No production reindexer is selected here.
final class IndexProjectionSpikeTests: XCTestCase {
    private typealias Rows = [String: String]

    private struct SwitchingRevision: CanonicalRevisionCalculating {
        let switchBranch: () throws -> Void
        func current(at root: URL) throws -> CanonicalRevision {
            try switchBranch()
            return try GitCanonicalRevisionCalculator().current(at: root)
        }
    }

    private func fixture() -> Document {
        var document = Document(name: "Projection spike")
        let app = EntityID("scope_app")
        let commerce = EntityID("scope_commerce")
        let checkout = EntityID("scope_checkout")
        let product = EntityID("scope_product")
        document.scopes = [
            ArchitectureScope(id: app, name: "App", parentID: nil),
            ArchitectureScope(id: commerce, name: "Commerce", parentID: app),
            ArchitectureScope(id: checkout, name: "Checkout", parentID: commerce),
            ArchitectureScope(id: product, name: "Product", parentID: commerce)
        ]
        let base = ComponentDefinition(id: EntityID("component_base"), name: "Base", ownerScopeID: app,
                                       root: Layer(id: EntityID("layer_base"), kind: .stack, name: "Base"))
        let nested = Layer(id: EntityID("layer_nested"), kind: .componentInstance, name: "Nested", component: ComponentInstance(definitionID: base.id))
        let wrapper = ComponentDefinition(id: EntityID("component_wrapper"), name: "Wrapper", ownerScopeID: app,
                                          root: Layer(id: EntityID("layer_wrapper"), kind: .stack, name: "Wrapper", children: [nested]))
        let other = ComponentDefinition(id: EntityID("component_other"), name: "Other", ownerScopeID: app,
                                        root: Layer(id: EntityID("layer_other"), kind: .stack, name: "Other"))
        let commerceOnly = ComponentDefinition(id: EntityID("component_commerce"), name: "CommerceOnly", ownerScopeID: commerce,
                                               root: Layer(id: EntityID("layer_commerce"), kind: .stack, name: "Commerce"))
        document.components = [base, wrapper, other, commerceOnly]
        let checkoutInstance = Layer(id: EntityID("checkout_instance"), kind: .componentInstance, name: "Wrapper", component: ComponentInstance(definitionID: wrapper.id))
        let productInstance = Layer(id: EntityID("product_instance"), kind: .componentInstance, name: "Other", component: ComponentInstance(definitionID: other.id))
        document.screens = [
            Screen(id: EntityID("screen_checkout"), name: "Checkout", scopeID: checkout,
                   root: Layer(id: EntityID("checkout_root"), kind: .stack, name: "Root", children: [checkoutInstance])),
            Screen(id: EntityID("screen_product"), name: "Product", scopeID: product,
                   root: Layer(id: EntityID("product_root"), kind: .stack, name: "Root", children: [productInstance]))
        ]
        document.tokens = [DesignToken(id: EntityID("token_spacing"), name: "Spacing", kind: .spacing, ownerScopeID: app, value: .literal("8"))]
        return document
    }

    private func rows(_ document: Document) -> Rows {
        let projection = IndexProjection(document: document)
        var result: Rows = [:]
        for row in projection.components {
            result["component:\(row.id.rawValue)"] = "\(row.name)|\(row.ownerScopeID.rawValue)|\(row.usageCount)"
        }
        for row in projection.scopeClosure {
            result["closure:\(row.consumer.rawValue):\(row.ancestor.rawValue)"] = "1"
        }
        for row in projection.availability {
            result["availability:\(row.consumer.rawValue):\(row.component.rawValue)"] = "1"
        }
        return result
    }

    private func changed(_ old: Rows, _ new: Rows) -> Set<String> {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }

    private func dependencies(in layer: Layer) -> Set<EntityID> {
        var result = Set(layer.component.map { [$0.definitionID] } ?? [])
        for child in layer.children { result.formUnion(dependencies(in: child)) }
        if let instance = layer.component {
            for slot in instance.slotContent.values {
                for child in slot { result.formUnion(dependencies(in: child)) }
            }
        }
        return result
    }

    private func reverseDependentDefinitions(of changedID: EntityID, in document: Document) -> Set<EntityID> {
        var affected: Set<EntityID> = [changedID]
        var previousCount = -1
        while previousCount != affected.count {
            previousCount = affected.count
            for definition in document.components where !dependencies(in: definition.root).isDisjoint(with: affected) {
                affected.insert(definition.id)
            }
        }
        return affected
    }

    private func screenUsage(_ screen: Screen) -> [EntityID: Int] {
        var counts: [EntityID: Int] = [:]
        func walk(_ layer: Layer) {
            if let id = layer.component?.definitionID { counts[id, default: 0] += 1 }
            for child in layer.children { walk(child) }
        }
        walk(screen.root)
        return counts
    }

    private func plan(_ kind: String, old: Document, new: Document) -> Set<String> {
        let oldRows = rows(old)
        let newRows = rows(new)
        let all = Set(oldRows.keys).union(newRows.keys)
        switch kind {
        case "availability":
            let dependents = reverseDependentDefinitions(of: EntityID("component_base"), in: new)
            return all.filter { key in
                key.hasPrefix("availability:") && dependents.contains { key.hasSuffix(":\($0.rawValue)") }
            }
        case "screenUsage":
            let before = screenUsage(old.screens[0])
            let after = screenUsage(new.screens[0])
            return Set(Set(before.keys).union(after.keys)
                .filter { before[$0, default: 0] != after[$0, default: 0] }
                .map { "component:\($0.rawValue)" })
        case "scopeParent":
            let moved = EntityID("scope_checkout")
            let oldScopes = ScopeEvaluator(old.scopes)
            let newScopes = ScopeEvaluator(new.scopes)
            let consumers = Set(old.scopes.map(\.id)).union(new.scopes.map(\.id)).filter { id in
                oldScopes.ancestorsIncludingSelf(of: id)?.contains(moved) == true ||
                newScopes.ancestorsIncludingSelf(of: id)?.contains(moved) == true
            }
            return all.filter { key in
                consumers.contains { key.hasPrefix("closure:\($0.rawValue):") || key.hasPrefix("availability:\($0.rawValue):") }
            }
        case "componentName":
            return ["component:component_other"]
        case "tokenValue":
            return [] // Current IndexProjection has no token usage view.
        default: fatalError("Unknown scenario")
        }
    }

    private func updated(_ kind: String, from old: Document) -> Document {
        var document = old
        switch kind {
        case "availability":
            document.components[0].availability.denyScopeIDs = [EntityID("scope_product")]
        case "screenUsage":
            document.screens[0].root.children.append(Layer(id: EntityID("new_base_instance"), kind: .componentInstance,
                                                            name: "Base", component: ComponentInstance(definitionID: EntityID("component_base"))))
        case "scopeParent":
            document.scopes[2].parentID = EntityID("scope_app")
            // Checkout's wrapper remains valid; CommerceOnly becomes unavailable there.
        case "componentName":
            document.components[2].name = "RenamedOther"
        case "tokenValue":
            document.tokens[0].value = .literal("12")
        default: fatalError("Unknown scenario")
        }
        return document
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }

    func testActualProjectionInvalidationAgainstFullOracle() throws {
        let old = fixture()
        let oldRows = rows(old)
        var cases: [[String: Any]] = []
        for kind in ["availability", "screenUsage", "scopeParent", "componentName", "tokenValue"] {
            let new = updated(kind, from: old)
            XCTAssertFalse(DocumentValidator.validate(new).contains { $0.severity == .error }, kind)
            let newRows = rows(new)
            let affected = plan(kind, old: old, new: new)
            let delta = changed(oldRows, newRows)
            XCTAssertTrue(delta.isSubset(of: affected), "missing invalidation: \(kind): \(delta.subtracting(affected))")
            var patched = oldRows
            for key in affected { patched.removeValue(forKey: key) }
            for key in affected { patched[key] = newRows[key] }
            XCTAssertEqual(patched, newRows, kind)
            cases.append(["scenario": kind, "changedRows": delta.sorted(), "invalidatedRows": affected.sorted(),
                          "changedCount": delta.count, "invalidatedCount": affected.count,
                          "matchesFullProjection": patched == newRows,
                          "beforeRows": oldRows, "afterRows": newRows])
        }

        var timings: [String: Any] = [:]
        for count in [4, 100, 1000] {
            var document = old
            if count > 4 {
                document.components += (4..<count).map { index in
                    ComponentDefinition(id: EntityID("component_extra_\(index)"), name: "Extra \(index)", ownerScopeID: EntityID("scope_app"),
                                        root: Layer(id: EntityID("layer_extra_\(index)"), kind: .stack, name: "Root"))
                }
            }
            let runs = count == 1000 ? 15 : 40
            var samples: [Double] = []
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = IndexProjection(document: document)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let next = updated("availability", from: document)
            timings[String(count)] = ["runs": runs, "rawMs": samples,
                                      "beforeRows": rows(document), "afterRows": rows(next),
                                      "affectedKeys": plan("availability", old: document, new: next).sorted(),
                                      "p50Ms": percentile(samples, 0.5), "p95Ms": percentile(samples, 0.95)] as [String: Any]
        }
        if let path = ProcessInfo.processInfo.environment["HAMII_PROJECTION_SPIKE_RESULT"] {
            let result: [String: Any] = ["cases": cases, "fullProjectionTimings": timings,
                                         "environment": "Swift 6.4 debug XCTest, macOS, in-process; no Canonical parser, Git, SQLite or CLI time"]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    func testActualIndexQueryRejectsBranchSwitchAfterReadingRows() throws {
        enum GitFailure: Error { case command(String) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw GitFailure.command(arguments.joined(separator: " ")) }
        }
        try git(["init", "-q", "-b", "main"])
        let repository = CanonicalRepository(root: root)
        var document = try repository.create(name: "Branch query")
        let created = document
        let owner = try XCTUnwrap(document.scopes.first?.id)
        document.components = [ComponentDefinition(id: EntityID("component_switch"), name: "BaseButton", ownerScopeID: owner,
                                                    root: Layer(id: EntityID("layer_switch"), kind: .stack, name: "Root"))]
        document.revision = 1
        try repository.save(document, expected: created)
        try git(["add", "-A"])
        try git(["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "main"])
        let storageRoot = temporary.appendingPathComponent("Indexes")
        let writer = try LocalIndex(projectRoot: root, documentID: document.id,
                                    revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: storageRoot)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        try writer.rebuild(from: snapshot, canonicalRevision: GitCanonicalRevisionCalculator().current(at: root))
        try git(["switch", "-qc", "other"])
        let file = root.appendingPathComponent("components/component_switch.json")
        let other = try String(decoding: Data(contentsOf: file), as: UTF8.self).replacingOccurrences(of: "BaseButton", with: "XaseButton")
        try Data(other.utf8).write(to: file)
        try git(["add", "-A"])
        try git(["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "other"])
        try git(["switch", "-q", "main"])
        let reader = try LocalIndex(projectRoot: root, documentID: document.id,
                                    revisionCalculator: SwitchingRevision(switchBranch: { try git(["switch", "-q", "other"]) }),
                                    storageRoot: storageRoot)
        XCTAssertThrowsError(try reader.components(matching: "Button", consumerScopeID: owner,
                                                    documentID: document.id, revision: 1,
                                                    expectedSourceIdentity: snapshot.identity)) { error in
            guard case IndexError.stale = error else { return XCTFail("Expected staleIndex, got \(error)") }
        }
        XCTAssertEqual(try repository.load().components.first?.name, "XaseButton")
    }

    func testProjectionUsesDocumentLoadedFromCanonicalFiles() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = CanonicalRepository(root: temporary)
        let created = try repository.create(name: "Projection files")
        var old = fixture()
        old.id = created.id
        old.revision = 1
        try repository.save(old, expected: created)
        let loaded = try repository.load()
        XCTAssertEqual(rows(loaded), rows(old))
        var next = updated("availability", from: loaded)
        next.revision = 2
        try repository.save(next, expected: loaded)
        XCTAssertEqual(rows(try repository.load()), rows(next))
    }
}
