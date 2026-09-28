import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

/// Test-only affected-key planner. Production recovery continues to rebuild the whole Index.
final class AffectedProjectionDependencySpikeTests: XCTestCase {
    private struct Change: Codable, Hashable {
        let kind: String
        let id: EntityID
    }

    private struct Usage: Codable, Hashable {
        let screen: String
        let component: String
        let count: Int
    }

    private struct Published {
        let generation: String
        let source: String
        let rows: [String: String]
        let usage: [Usage]
    }

    private struct Affected {
        var components = Set<String>()
        var closure = Set<String>()
        var availability = Set<String>()
        var all: Set<String> { components.union(closure).union(availability) }
    }

    private struct Plan {
        let affected: Affected
        let impactedCurrent: Set<String>
        let impactedUnion: Set<String>
        let impactedAll: Set<String>
        let sourceIdentity: String?

        func isBound(to identity: String) -> Bool { sourceIdentity == identity }
    }

    private enum ProbeError: Error { case invalidSummary, unsupportedInput }

    /// The candidate historical summary is published with old rows and identity in one SQLite transaction.
    private final class SummaryStore {
        let url: URL
        private var db: OpaquePointer?

        init(url: URL) throws {
            self.url = url
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ProbeError.invalidSummary }
            try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS rows (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            // Deliberately allow duplicate summary rows so the read gate has to reject them.
            try execute("CREATE TABLE IF NOT EXISTS usage (screen TEXT, component TEXT, count INTEGER)")
        }

        deinit { sqlite3_close(db) }

        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ProbeError.invalidSummary }
        }

        private func insert(_ sql: String, _ values: [String]) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ProbeError.invalidSummary }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in values.enumerated() {
                guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                    throw ProbeError.invalidSummary
                }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ProbeError.invalidSummary }
        }

        private func readPairs(_ sql: String, columns: Int) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ProbeError.invalidSummary }
            defer { sqlite3_finalize(statement) }
            var result: [[String]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw ProbeError.invalidSummary }
                result.append((0..<columns).map { index in
                    guard let text = sqlite3_column_text(statement, Int32(index)) else { return "" }
                    return String(cString: text)
                })
            }
        }

        static func digest(_ fields: [[String]]) -> String {
            var hash = SHA256()
            for row in fields.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                for field in row {
                    let bytes = Data(field.utf8)
                    var length = UInt64(bytes.count).bigEndian
                    withUnsafeBytes(of: &length) { hash.update(data: $0) }
                    hash.update(data: bytes)
                }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        func publish(_ value: Published, beforeCommit: (() throws -> Void)? = nil) throws {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute("DELETE FROM meta")
                try execute("DELETE FROM rows")
                try execute("DELETE FROM usage")
                let rowFields = value.rows.map { [$0.key, $0.value] }
                let usageFields = value.usage.map { [$0.screen, $0.component, String($0.count)] }
                for row in rowFields { try insert("INSERT INTO rows VALUES (?,?)", row) }
                for row in usageFields { try insert("INSERT INTO usage VALUES (?,?,?)", row) }
                let meta = ["generation": value.generation, "source": value.source,
                            "summaryVersion": "1", "rowDigest": Self.digest(rowFields),
                            "usageDigest": Self.digest(usageFields), "usageCount": String(usageFields.count)]
                for (key, val) in meta { try insert("INSERT INTO meta VALUES (?,?)", [key, val]) }
                try beforeCommit?()
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }

        func read(generation: String, source: String) throws -> Published? {
            let metadata = try readPairs("SELECT key,value FROM meta", columns: 2)
            guard metadata.count == Set(metadata.map { $0[0] }).count else { return nil }
            let meta = Dictionary(uniqueKeysWithValues: metadata.map { ($0[0], $0[1]) })
            guard meta["generation"] == generation, meta["source"] == source,
                  meta["summaryVersion"] == "1" else { return nil }
            let rowFields = try readPairs("SELECT key,value FROM rows", columns: 2)
            let usageFields = try readPairs("SELECT screen,component,count FROM usage", columns: 3)
            guard meta["rowDigest"] == Self.digest(rowFields),
                  meta["usageDigest"] == Self.digest(usageFields),
                  meta["usageCount"] == String(usageFields.count),
                  Set(usageFields.map { "\($0[0]):\($0[1])" }).count == usageFields.count,
                  usageFields.allSatisfy({ Int($0[2]).map { $0 > 0 } == true }) else { return nil }
            let usage = usageFields.compactMap { row -> Usage? in
                guard let count = Int(row[2]) else { return nil }
                return Usage(screen: row[0], component: row[1], count: count)
            }
            return Published(generation: generation, source: source,
                             rows: Dictionary(uniqueKeysWithValues: rowFields.map { ($0[0], $0[1]) }), usage: usage)
        }

        /// Isolated summary read cost; callers must validate the published Index rows separately.
        func readUsageOnly(generation: String, source: String) throws -> [Usage]? {
            let metadata = try readPairs("SELECT key,value FROM meta", columns: 2)
            let meta = Dictionary(uniqueKeysWithValues: metadata.map { ($0[0], $0[1]) })
            guard meta["generation"] == generation, meta["source"] == source,
                  meta["summaryVersion"] == "1" else { return nil }
            let fields = try readPairs("SELECT screen,component,count FROM usage", columns: 3)
            guard meta["usageDigest"] == Self.digest(fields),
                  meta["usageCount"] == String(fields.count),
                  Set(fields.map { "\($0[0]):\($0[1])" }).count == fields.count,
                  fields.allSatisfy({ Int($0[2]).map { $0 > 0 } == true }) else { return nil }
            return fields.compactMap { row in Int(row[2]).map { Usage(screen: row[0], component: row[1], count: $0) } }
        }
    }

    private static func rows(_ document: Document) -> [String: String] {
        let projection = IndexProjection(document: document)
        var rows: [String: String] = [:]
        for item in projection.components {
            rows["component:\(item.id.rawValue)"] = "\(item.name)|\(item.ownerScopeID.rawValue)|\(item.usageCount)"
        }
        for item in projection.scopeClosure {
            rows["closure:\(item.consumer.rawValue):\(item.ancestor.rawValue)"] = "1"
        }
        for item in projection.availability {
            rows["availability:\(item.consumer.rawValue):\(item.component.rawValue)"] = "1"
        }
        return rows
    }

    // Matches IndexProjection.collectUsage: slotContent is deliberately not traversed.
    private static func usage(_ screen: Screen) -> [String: Int] {
        var result: [String: Int] = [:]
        func visit(_ layer: Layer) {
            if let id = layer.component?.definitionID.rawValue { result[id, default: 0] += 1 }
            for child in layer.children { visit(child) }
        }
        visit(screen.root)
        return result
    }

    private static func usageSummary(_ document: Document) -> [Usage] {
        document.screens.flatMap { screen in
            usage(screen).map { Usage(screen: screen.id.rawValue, component: $0.key, count: $0.value) }
        }.sorted { ($0.screen, $0.component) < ($1.screen, $1.component) }
    }

    // Mirrors ComponentAvailability.dependencies(in:), including nested slot content.
    private static func dependencies(_ layer: Layer) -> Set<String> {
        var result = Set(layer.component.map { [$0.definitionID.rawValue] } ?? [])
        for child in layer.children { result.formUnion(dependencies(child)) }
        if let instance = layer.component {
            for name in instance.slotContent.keys.sorted() {
                for child in instance.slotContent[name] ?? [] { result.formUnion(dependencies(child)) }
            }
        }
        return result
    }

    private static func graph(_ document: Document) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: document.components.map { ($0.id.rawValue, dependencies($0.root)) })
    }

    private static func reverseClosure(_ seeds: Set<String>, graph: [String: Set<String>]) -> Set<String> {
        var affected = seeds
        var pending = Array(seeds)
        var reverse: [String: Set<String>] = [:]
        for (owner, dependencies) in graph {
            for dependency in dependencies { reverse[dependency, default: []].insert(owner) }
        }
        while let item = pending.popLast() {
            for owner in reverse[item, default: []] where affected.insert(owner).inserted {
                pending.append(owner)
            }
        }
        return affected
    }

    private static func published(_ document: Document) -> Published {
        Published(generation: UUID().uuidString, source: UUID().uuidString,
                  rows: rows(document), usage: usageSummary(document))
    }

    private static func plan(_ changes: Set<Change>, current: Document, published: Published,
                             oldGraphForComparison: [String: Set<String>] = [:],
                             sourceIdentity: String? = nil) throws -> Plan {
        guard changes.allSatisfy({ ["components", "screens", "scopes"].contains($0.kind) }) else {
            throw ProbeError.unsupportedInput
        }
        let usageKeys = published.usage.map { "\($0.screen):\($0.component)" }
        guard Set(usageKeys).count == usageKeys.count,
              published.usage.allSatisfy({ $0.count > 0 && !$0.screen.isEmpty && !$0.component.isEmpty }) else {
            throw ProbeError.invalidSummary
        }
        let changedComponents = Set(changes.filter { $0.kind == "components" }.map { $0.id.rawValue })
        let changedScreens = Set(changes.filter { $0.kind == "screens" }.map { $0.id.rawValue })
        let changedScopes = Set(changes.filter { $0.kind == "scopes" }.map { $0.id.rawValue })
        let currentScopes = Set(current.scopes.map { $0.id.rawValue })
        let oldScopes = Set(published.rows.keys.filter { $0.hasPrefix("closure:") }.compactMap {
            $0.split(separator: ":").dropFirst().first.map(String.init)
        })
        let oldComponents = Set(published.rows.keys.filter { $0.hasPrefix("component:") }.map { String($0.dropFirst(10)) })
        let currentComponents = Set(current.components.map { $0.id.rawValue })
        var affected = Affected()

        for component in changedComponents { affected.components.insert("component:\(component)") }
        let currentScreens = Dictionary(uniqueKeysWithValues: current.screens.map { ($0.id.rawValue, $0) })
        var oldChangedUsage: [String: Int] = [:]
        for item in published.usage where changedScreens.contains(item.screen) {
            oldChangedUsage[item.component, default: 0] += item.count
        }
        var newChangedUsage: [String: Int] = [:]
        for screenID in changedScreens {
            if let screen = currentScreens[screenID] {
                for (component, count) in usage(screen) { newChangedUsage[component, default: 0] += count }
            }
        }
        for component in Set(oldChangedUsage.keys).union(newChangedUsage.keys)
            where oldChangedUsage[component, default: 0] != newChangedUsage[component, default: 0] {
            affected.components.insert("component:\(component)")
        }

        let newGraph = graph(current)
        let impactedCurrent = reverseClosure(changedComponents, graph: newGraph)
        var unionGraph = newGraph
        for (owner, edges) in oldGraphForComparison { unionGraph[owner, default: []].formUnion(edges) }
        let impactedUnion = reverseClosure(changedComponents, graph: unionGraph)
        let impactedAll = oldComponents.union(currentComponents)
        for component in impactedCurrent {
            for scope in oldScopes.union(currentScopes) {
                affected.availability.insert("availability:\(scope):\(component)")
            }
        }

        let oldClosure = published.rows.keys.filter { $0.hasPrefix("closure:") }
        let oldAffectedConsumers = Set(oldClosure.compactMap { key -> String? in
            let parts = key.split(separator: ":")
            guard parts.count == 3, changedScopes.contains(String(parts[2])) else { return nil }
            return String(parts[1])
        })
        let evaluator = ScopeEvaluator(current.scopes)
        let newAffectedConsumers = Set(current.scopes.compactMap { scope -> String? in
            guard let ancestors = evaluator.ancestorsIncludingSelf(of: scope.id),
                  ancestors.contains(where: { changedScopes.contains($0.rawValue) }) else { return nil }
            return scope.id.rawValue
        })
        for consumer in oldAffectedConsumers.union(newAffectedConsumers) {
            affected.closure.formUnion(oldClosure.filter { $0.hasPrefix("closure:\(consumer):") })
            if let ancestors = evaluator.ancestorsIncludingSelf(of: EntityID(consumer)) {
                for ancestor in ancestors { affected.closure.insert("closure:\(consumer):\(ancestor.rawValue)") }
            }
            for component in oldComponents.union(currentComponents) {
                affected.availability.insert("availability:\(consumer):\(component)")
            }
        }
        return Plan(affected: affected, impactedCurrent: impactedCurrent,
                    impactedUnion: impactedUnion, impactedAll: impactedAll, sourceIdentity: sourceIdentity)
    }

    private static func actual(_ old: [String: String], _ new: [String: String]) -> Set<String> {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }

    private static func assertOracle(_ plan: Plan, old: Published, current: Document,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let newRows = rows(current) // Oracle is evaluated only after planning.
        let changed = actual(old.rows, newRows)
        XCTAssertTrue(changed.isSubset(of: plan.affected.all),
                      "Missed rows: \(changed.subtracting(plan.affected.all).sorted())", file: file, line: line)
        var patched = old.rows
        for key in plan.affected.all { patched.removeValue(forKey: key) }
        for key in plan.affected.all { patched[key] = newRows[key] }
        XCTAssertEqual(patched, newRows, file: file, line: line)
    }

    private func fixture() -> Document {
        var document = Document(name: "Affected projection")
        let app = EntityID("scope_app")
        document.scopes = [ArchitectureScope(id: app, name: "App", parentID: nil),
                           ArchitectureScope(id: EntityID("scope_child"), name: "Child", parentID: app),
                           ArchitectureScope(id: EntityID("scope_leaf"), name: "Leaf", parentID: EntityID("scope_child")),
                           ArchitectureScope(id: EntityID("scope_other"), name: "Other", parentID: app)]
        func instance(_ id: String, _ definition: String) -> Layer {
            Layer(id: EntityID(id), kind: .componentInstance, name: id,
                  component: ComponentInstance(definitionID: EntityID(definition)))
        }
        let b = ComponentDefinition(id: EntityID("component_b"), name: "B", ownerScopeID: app,
                                    root: Layer(id: EntityID("root_b"), kind: .stack, name: "B"))
        let a = ComponentDefinition(id: EntityID("component_a"), name: "A", ownerScopeID: app,
                                    root: Layer(id: EntityID("root_a"), kind: .stack, name: "A",
                                                children: [instance("a_to_b", "component_b")]))
        let x = ComponentDefinition(id: EntityID("component_x"), name: "X", ownerScopeID: app,
                                    root: Layer(id: EntityID("root_x"), kind: .stack, name: "X",
                                                children: [instance("x_to_a", "component_a")]))
        let other = ComponentDefinition(id: EntityID("component_other"), name: "Other", ownerScopeID: app,
                                        root: Layer(id: EntityID("root_other"), kind: .stack, name: "Other"))
        document.components = [b, a, x, other]
        document.screens = [Screen(id: EntityID("screen_main"), name: "Main", scopeID: app,
                                   root: Layer(id: EntityID("screen_root"), kind: .stack, name: "Root",
                                               children: [instance("screen_to_other", "component_other")]))]
        return document
    }

    private static func sourceChanges(old: Document, new: Document) throws -> Set<Change> {
        func changed<T: Encodable & Identifiable>(_ lhs: [T], _ rhs: [T], kind: String) throws -> Set<Change>
            where T.ID == EntityID {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let a = try Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, try encoder.encode($0)) })
            let b = try Dictionary(uniqueKeysWithValues: rhs.map { ($0.id, try encoder.encode($0)) })
            return Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.map { Change(kind: kind, id: $0) }.reduce(into: []) { $0.insert($1) }
        }
        return try changed(old.components, new.components, kind: "components")
            .union(changed(old.screens, new.screens, kind: "screens"))
            .union(changed(old.scopes, new.scopes, kind: "scopes"))
    }

    private static func sourceChanges(old: [String: String], new: [String: String]) throws -> Set<Change> {
        var result: Set<Change> = []
        for path in Set(old.keys).union(new.keys) where old[path] != new[path] {
            if path == "hamii.json" { continue }
            let parts = path.split(separator: "/")
            guard parts.count == 2, ["components", "screens", "scopes"].contains(String(parts[0])),
                  parts[1].hasSuffix(".json") else { throw ProbeError.unsupportedInput }
            result.insert(Change(kind: String(parts[0]), id: EntityID(String(parts[1].dropLast(5)))))
        }
        return result
    }

    private static func validate(_ document: Document, file: StaticString = #filePath, line: UInt = #line) {
        let errors = DocumentValidator.validate(document).filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "Invalid fixture: \(errors)", file: file, line: line)
    }

    func testComponentGraphCandidatesAgainstFullProjection() throws {
        let baseline = fixture()
        Self.validate(baseline)
        var report: [[String: Any]] = []
        for scenario in ["basePolicy", "baseOwner", "oldEdgeRemoval", "newEdgeAddition", "transitiveRemoval",
                         "transitiveAddition", "deleteBase", "addBase", "renameBase", "nestedChild", "slotContent",
                         "nameOnly", "nativeOnly"] {
            var before = baseline
            if ["oldEdgeRemoval", "newEdgeAddition", "transitiveRemoval"].contains(scenario) {
                before.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
            }
            let old = Self.published(before)
            let graph = Self.graph(before)
            var next = before
            switch scenario {
            case "basePolicy": next.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
            case "baseOwner": next.components[0].ownerScopeID = EntityID("scope_other")
                // Existing dependent Components must be valid in their own scope, so re-own them too.
                next.components[1].ownerScopeID = EntityID("scope_other")
                next.components[2].ownerScopeID = EntityID("scope_other")
            case "oldEdgeRemoval": next.components[1].root.children = []
            case "newEdgeAddition": next.components[3].root.children = [Layer(id: EntityID("other_to_b"), kind: .componentInstance,
                name: "B", component: ComponentInstance(definitionID: EntityID("component_b")))]
            case "transitiveRemoval": next.components[1].root.children = []
            case "transitiveAddition": next.components[3].root.children = [Layer(id: EntityID("other_to_a"), kind: .componentInstance,
                name: "A", component: ComponentInstance(definitionID: EntityID("component_a")))]
                next.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
            case "deleteBase": next.components.remove(at: 0); next.components[0].root.children = []
            case "addBase": next.components.append(ComponentDefinition(id: EntityID("component_new"), name: "New",
                ownerScopeID: EntityID("scope_app"), root: Layer(id: EntityID("root_new"), kind: .stack, name: "New")))
                next.components[1].root.children = [Layer(id: EntityID("a_to_new"), kind: .componentInstance,
                    name: "New", component: ComponentInstance(definitionID: EntityID("component_new")))]
            case "renameBase": next.components[0].id = EntityID("component_b_new")
                next.components[1].root.children[0].component?.definitionID = EntityID("component_b_new")
            case "nestedChild": next.components[1].root.children = [Layer(id: EntityID("nested_stack"), kind: .stack,
                name: "Nested", children: [Layer(id: EntityID("nested_b"), kind: .componentInstance,
                    name: "B", component: ComponentInstance(definitionID: EntityID("component_b")))])]
                next.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
            case "slotContent": var host = ComponentInstance(definitionID: EntityID("component_b"))
                host.slotContent["content"] = [Layer(id: EntityID("slot_a"), kind: .componentInstance,
                    name: "A", component: ComponentInstance(definitionID: EntityID("component_a")))]
                next.components[3].root.children = [Layer(id: EntityID("slot_host"), kind: .componentInstance,
                    name: "Host", component: host)]
                next.components[0].api.slots = [ComponentSlot(name: "content", targetLayerID: EntityID("root_b"))]
                next.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
            case "nameOnly": next.components[0].name = "Renamed B"
            case "nativeOnly": next.components[0].nativeSemantics["hint"] = "native"
            default: XCTFail("Unknown scenario")
            }
            Self.validate(next)
            let changes = try Self.sourceChanges(old: before, new: next)
            let plan = try Self.plan(changes, current: next, published: old, oldGraphForComparison: graph)
            Self.assertOracle(plan, old: old, current: next)
            let actual = Self.actual(old.rows, Self.rows(next))
            report.append(["scenario": scenario, "changedComponents": changes.filter { $0.kind == "components" }.map { $0.id.rawValue }.sorted(),
                           "actualRows": actual.count, "plannedRows": plan.affected.all.count,
                           "impactedCurrent": plan.impactedCurrent.sorted(), "impactedUnion": plan.impactedUnion.sorted(),
                           "impactedAll": plan.impactedAll.sorted(), "missingRows": actual.subtracting(plan.affected.all).sorted()])
        }
        if let output = ProcessInfo.processInfo.environment["HAMII_AFFECTED_MATRIX_RESULT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }

    func testScreenAndScopeAffectedKeysAgainstFullProjection() throws {
        let baseline = fixture()
        Self.validate(baseline)
        let old = Self.published(baseline)
        var report: [[String: Any]] = []
        for scenario in ["usageAdd", "usageRemove", "screenAdd", "screenDelete", "countTwoToOne", "countOneToZero",
                         "screenName", "scopeMove", "scopeMoveDescendants", "scopeAdd", "scopeDelete",
                         "scopeDeleteReparent", "scopeName", "combined"] {
            var next = baseline
            func instance(_ id: String) -> Layer {
                Layer(id: EntityID(id), kind: .componentInstance, name: id,
                      component: ComponentInstance(definitionID: EntityID("component_b")))
            }
            switch scenario {
            case "usageAdd": next.screens[0].root.children.append(instance("screen_added_b"))
            case "usageRemove", "countOneToZero": next.screens[0].root.children.removeAll()
            case "screenAdd": next.screens.append(Screen(id: EntityID("screen_new"), name: "New",
                scopeID: EntityID("scope_app"), root: Layer(id: EntityID("screen_new_root"), kind: .stack,
                    name: "Root", children: [instance("screen_new_b")])))
            case "screenDelete": next.screens.removeAll()
            case "countTwoToOne":
                // This case has a dedicated old source with two instances of B.
                var two = baseline
                two.screens[0].root.children = [instance("screen_first_b"), instance("screen_second_b")]
                next = two
                next.screens[0].root.children.removeLast()
                let published = Self.published(two)
                let changes = try Self.sourceChanges(old: two, new: next)
                Self.validate(two); Self.validate(next)
                let plan = try Self.plan(changes, current: next, published: published)
                Self.assertOracle(plan, old: published, current: next)
                report.append(["scenario": scenario, "actualRows": Self.actual(published.rows, Self.rows(next)).count,
                               "plannedRows": plan.affected.all.count, "missingRows": []])
                continue
            case "screenName": next.screens[0].name = "Renamed"
            case "scopeMove": next.scopes[1].parentID = EntityID("scope_other")
            case "scopeMoveDescendants": next.scopes[1].parentID = EntityID("scope_other")
                next.components[0].availability.denyScopeIDs = [EntityID("scope_leaf")]
            case "scopeAdd": next.scopes.append(ArchitectureScope(id: EntityID("scope_new"), name: "New",
                parentID: EntityID("scope_child")))
            case "scopeDelete": next.scopes.remove(at: 2)
            case "scopeDeleteReparent": next.scopes.remove(at: 1)
                next.scopes[1].parentID = EntityID("scope_app")
            case "scopeName": next.scopes[1].name = "Renamed"
            case "combined": next.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
                next.screens[0].root.children.append(instance("screen_combined_b"))
                next.scopes[1].parentID = EntityID("scope_other")
            default: XCTFail("Unknown scenario")
            }
            Self.validate(next)
            let changes = try Self.sourceChanges(old: baseline, new: next)
            let plan = try Self.plan(changes, current: next, published: old)
            Self.assertOracle(plan, old: old, current: next)
            let actual = Self.actual(old.rows, Self.rows(next))
            report.append(["scenario": scenario, "actualRows": actual.count,
                           "plannedRows": plan.affected.all.count,
                           "missingRows": actual.subtracting(plan.affected.all).sorted()])
        }
        if let output = ProcessInfo.processInfo.environment["HAMII_AFFECTED_SCOPE_SCREEN_RESULT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }

    func testPerScreenHistoryCannotBeReconstructedFromAggregateUsage() throws {
        var first = fixture()
        var second = first
        let bInstance = Layer(id: EntityID("screen_b_instance"), kind: .componentInstance, name: "B",
                              component: ComponentInstance(definitionID: EntityID("component_b")))
        first.screens[0].root.children = [bInstance]
        first.screens.append(Screen(id: EntityID("screen_other"), name: "Other", scopeID: EntityID("scope_app"),
            root: Layer(id: EntityID("other_screen_root"), kind: .stack, name: "Root")))
        second.screens[0].root.children = []
        second.screens.append(Screen(id: EntityID("screen_other"), name: "Other", scopeID: EntityID("scope_app"),
            root: Layer(id: EntityID("other_screen_root"), kind: .stack, name: "Root",
                children: [Layer(id: EntityID("other_b_instance"), kind: .componentInstance, name: "B",
                    component: ComponentInstance(definitionID: EntityID("component_b")))])))
        Self.validate(first); Self.validate(second)
        let firstRows = Self.rows(first)
        XCTAssertEqual(firstRows, Self.rows(second), "Published aggregate rows must be indistinguishable")
        var firstNext = first
        firstNext.screens[0].root.children = []
        var secondNext = second
        secondNext.screens[0].name = "Changed"
        let firstPlan = try Self.plan(Self.sourceChanges(old: first, new: firstNext), current: firstNext,
                                      published: Self.published(first))
        let secondPlan = try Self.plan(Self.sourceChanges(old: second, new: secondNext), current: secondNext,
                                       published: Self.published(second))
        XCTAssertTrue(firstPlan.affected.components.contains("component:component_b"))
        XCTAssertFalse(secondPlan.affected.components.contains("component:component_b"))
        Self.assertOracle(firstPlan, old: Self.published(first), current: firstNext)
        Self.assertOracle(secondPlan, old: Self.published(second), current: secondNext)
    }

    func testSummaryGenerationBindingAtomicVisibilityAndCorruptionFallback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-affected-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SummaryStore(url: url)
        let reader = try SummaryStore(url: url)
        let base = fixture()
        let first = Self.published(base)
        try writer.publish(first)
        XCTAssertEqual(try reader.read(generation: first.generation, source: first.source)?.usage, first.usage)
        XCTAssertEqual(try reader.readUsageOnly(generation: first.generation, source: first.source), first.usage)
        XCTAssertNil(try reader.read(generation: UUID().uuidString, source: first.source))
        XCTAssertNil(try reader.read(generation: first.generation, source: UUID().uuidString))
        var nextDocument = base
        nextDocument.screens[0].root.children = []
        let second = Self.published(nextDocument)
        try writer.publish(second) {
            XCTAssertEqual(try reader.read(generation: first.generation, source: first.source)?.rows, first.rows)
            XCTAssertNil(try reader.read(generation: second.generation, source: second.source))
        }
        XCTAssertNil(try reader.read(generation: first.generation, source: first.source))
        XCTAssertEqual(try reader.read(generation: second.generation, source: second.source)?.rows, second.rows)
        enum Stop: Error { case beforeCommit }
        XCTAssertThrowsError(try writer.publish(first) { throw Stop.beforeCommit })
        XCTAssertEqual(try reader.read(generation: second.generation, source: second.source)?.rows, second.rows)
        for corruption in ["DELETE FROM usage", "INSERT INTO usage SELECT * FROM usage LIMIT 1",
                           "UPDATE usage SET count=0", "UPDATE meta SET value='2' WHERE key='summaryVersion'",
                           "UPDATE meta SET value='wrong' WHERE key='source'",
                           "UPDATE meta SET value='wrong' WHERE key='generation'",
                           "DELETE FROM meta WHERE key='usageDigest'", "DELETE FROM rows WHERE key LIKE 'component:%'"] {
            try writer.publish(first)
            try writer.execute(corruption)
            XCTAssertNil(try reader.read(generation: first.generation, source: first.source), corruption)
        }
    }

    func testDeterministicAcyclicGraphEnumeration() throws {
        let baseline = fixture()
        let edges = [(1, 0), (2, 0), (2, 1), (3, 0), (3, 1), (3, 2)]
        func document(_ mask: Int) -> Document {
            var result = baseline
            result.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
            for owner in 0..<4 {
                result.components[owner].root.children = edges.enumerated().compactMap { bit, edge -> Layer? in
                    guard edge.0 == owner, (mask & (1 << bit)) != 0 else { return nil }
                    let target = result.components[edge.1].id
                    return Layer(id: EntityID("edge_\(owner)_\(edge.1)"), kind: .componentInstance,
                                 name: "Dependency", component: ComponentInstance(definitionID: target))
                }
            }
            return result
        }
        var pairs = 0
        var actualAvailabilityChanges = 0
        var unionExtra = 0
        var maximumCurrent = 0
        for mask in 0..<(1 << edges.count) {
            let oldDocument = document(mask)
            Self.validate(oldDocument)
            let published = Self.published(oldDocument)
            let oldGraph = Self.graph(oldDocument)
            for bit in 0..<edges.count {
                let current = document(mask ^ (1 << bit))
                Self.validate(current)
                let changes = try Self.sourceChanges(old: oldDocument, new: current)
                let plan = try Self.plan(changes, current: current, published: published,
                                         oldGraphForComparison: oldGraph)
                Self.assertOracle(plan, old: published, current: current)
                let changedAvailability = Set(Self.actual(published.rows, Self.rows(current))
                    .filter { $0.hasPrefix("availability:") }
                    .compactMap { $0.split(separator: ":").last.map(String.init) })
                XCTAssertTrue(changedAvailability.isSubset(of: plan.impactedCurrent),
                              "mask=\(mask) bit=\(bit) missing=\(changedAvailability.subtracting(plan.impactedCurrent))")
                pairs += 1
                actualAvailabilityChanges += changedAvailability.count
                unionExtra += plan.impactedUnion.subtracting(plan.impactedCurrent).count
                maximumCurrent = max(maximumCurrent, plan.impactedCurrent.count)
            }
        }
        XCTAssertEqual(pairs, 384)
        if let output = ProcessInfo.processInfo.environment["HAMII_AFFECTED_GRAPH_RESULT"] {
            let report: [String: Any] = ["validOldNewPairs": pairs,
                "actualAvailabilityChangedComponentsAcrossPairs": actualAvailabilityChanges,
                "unionOnlyImpactedComponentsAcrossPairs": unionExtra,
                "maximumCurrentImpactedComponents": maximumCurrent, "falseNegatives": 0]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }

    func testFreshProcessReadsBoundSummaryAndLaterSaveInvalidatesPlan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-affected-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Project")
        let repository = CanonicalRepository(root: project)
        let created = try repository.create(name: "Affected restart")
        var oldDocument = fixture()
        oldDocument.id = created.id
        oldDocument.revision = created.revision + 1
        try repository.save(oldDocument, expected: created)
        let oldCapture = try repository.withStableSinglePassProbe(captureFileDigests: true) { probe, _ in probe }
        let oldSource = oldCapture.snapshot.identity.rawValue
        let old = Published(generation: UUID().uuidString, source: oldSource,
                            rows: Self.rows(oldDocument), usage: Self.usageSummary(oldDocument))
        let database = directory.appendingPathComponent("summary.sqlite")
        try SummaryStore(url: database).publish(old)
        var current = oldDocument
        current.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
        current.revision += 1
        try repository.save(current, expected: oldDocument)
        let newCapture = try repository.withStableSinglePassProbe(captureFileDigests: true) { probe, _ in probe }
        let newSource = newCapture.snapshot.identity.rawValue
        let sourceChanges = try Self.sourceChanges(old: oldCapture.fileDigests, new: newCapture.fileDigests)
        XCTAssertEqual(sourceChanges, try Self.sourceChanges(old: oldDocument, new: current))
        let result = directory.appendingPathComponent("worker.json")
        let changesFile = directory.appendingPathComponent("changes.json")
        try JSONEncoder().encode(Array(sourceChanges)).write(to: changesFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest", "HamiiTests.AffectedProjectionDependencySpikeTests/testRestartWorker", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HAMII_AFFECTED_RESTART_PROJECT"] = project.path
        environment["HAMII_AFFECTED_RESTART_DATABASE"] = database.path
        environment["HAMII_AFFECTED_RESTART_GENERATION"] = old.generation
        environment["HAMII_AFFECTED_RESTART_SOURCE"] = old.source
        environment["HAMII_AFFECTED_RESTART_CHANGES"] = changesFile.path
        environment["HAMII_AFFECTED_RESTART_RESULT"] = result.path
        for imageIndex in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(imageIndex) else { continue }
            let path = String(cString: name)
            if path.hasSuffix("/libTesting.dylib") {
                environment["DYLD_LIBRARY_PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path
                break
            }
        }
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        let output = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        let keys = try JSONDecoder().decode([String].self, from: Data(contentsOf: result))
        let loaded = try XCTUnwrap(SummaryStore(url: database).read(generation: old.generation, source: old.source))
        let plan = try Self.plan(sourceChanges, current: current,
                                 published: loaded, sourceIdentity: newSource)
        XCTAssertEqual(Set(keys), plan.affected.all)
        XCTAssertTrue(plan.isBound(to: newSource))
        Self.assertOracle(plan, old: loaded, current: current)
        var later = current
        later.components[3].name = "After plan"
        later.revision += 1
        try repository.save(later, expected: current)
        let laterSource = try repository.withStableSinglePassProbe { probe, _ in probe.snapshot.identity.rawValue }
        XCTAssertFalse(plan.isBound(to: laterSource), "Captured plan must not publish after a later save")
    }

    func testRestartWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let project = environment["HAMII_AFFECTED_RESTART_PROJECT"],
              let database = environment["HAMII_AFFECTED_RESTART_DATABASE"],
              let generation = environment["HAMII_AFFECTED_RESTART_GENERATION"],
              let source = environment["HAMII_AFFECTED_RESTART_SOURCE"],
              let changesFile = environment["HAMII_AFFECTED_RESTART_CHANGES"],
              let result = environment["HAMII_AFFECTED_RESTART_RESULT"] else {
            throw XCTSkip("Subprocess only")
        }
        let repository = CanonicalRepository(root: URL(fileURLWithPath: project))
        let current = try repository.load()
        let old = try XCTUnwrap(SummaryStore(url: URL(fileURLWithPath: database)).read(generation: generation, source: source))
        let changes = try Set(JSONDecoder().decode([Change].self, from: Data(contentsOf: URL(fileURLWithPath: changesFile))))
        let plan = try Self.plan(changes, current: current, published: old)
        try JSONEncoder().encode(plan.affected.all.sorted()).write(to: URL(fileURLWithPath: result))
    }

    private func percentile(_ samples: [Double], _ proportion: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * proportion)) - 1)]
    }

    func testMeasuredDependencyPlanningCost() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_AFFECTED_BENCHMARK_RESULT"] else {
            throw XCTSkip("Run explicitly for Spike benchmark")
        }
        var reports: [[String: Any]] = []
        for (name, count) in [("independent-1000", 1000), ("independent-5000", 5000),
                              ("mixed", 100), ("chain", 100), ("fanout", 500)] {
            var old = fixture()
            for number in 4..<count {
                old.components.append(ComponentDefinition(id: EntityID("component_\(number)"), name: "Component \(number)",
                    ownerScopeID: EntityID("scope_app"), root: Layer(id: EntityID("root_\(number)"), kind: .stack, name: "Root")))
            }
            if name == "mixed" {
                for number in 0..<8 {
                    old.scopes.append(ArchitectureScope(id: EntityID("scope_mixed_\(number)"), name: "Mixed \(number)",
                                                        parentID: EntityID("scope_app")))
                }
                for number in 0..<20 {
                    old.screens.append(Screen(id: EntityID("screen_mixed_\(number)"), name: "Mixed \(number)",
                        scopeID: EntityID("scope_app"), root: Layer(id: EntityID("screen_root_\(number)"),
                            kind: .stack, name: "Root")))
                }
            }
            if name == "chain" {
                // Acyclic chain, with the changed B at the leaf.
                for number in 4..<count {
                    let target = number == 4 ? EntityID("component_x") : EntityID("component_\(number - 1)")
                    old.components[number].root.children = [Layer(id: EntityID("chain_edge_\(number)"),
                        kind: .componentInstance, name: "Dependency", component: ComponentInstance(definitionID: target))]
                }
            }
            if name == "fanout" {
                for number in 4..<count {
                    old.components[number].root.children = [Layer(id: EntityID("fanout_edge_\(number)"),
                        kind: .componentInstance, name: "Dependency",
                        component: ComponentInstance(definitionID: EntityID("component_b")))]
                }
            }
            Self.validate(old)
            let published = Self.published(old)
            var current = old
            current.components[0].availability.denyScopeIDs = [EntityID("scope_child")]
            let changes: Set<Change> = [Change(kind: "components", id: EntityID("component_b"))]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-plan-bench-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try SummaryStore(url: url)
            var measures: [String: [Double]] = [:]
            func measure(_ name: String, _ action: () throws -> Void) rethrows {
                let started = ProcessInfo.processInfo.systemUptime
                try action()
                measures[name, default: []].append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            }
            for _ in 0..<5 {
                try measure("summarySQLiteWrite") { try store.publish(published) }
                try measure("summarySQLiteRead") {
                    XCTAssertNotNil(try store.read(generation: published.generation, source: published.source))
                }
                try measure("usageSummarySQLiteReadOnly") {
                    XCTAssertEqual(try store.readUsageOnly(generation: published.generation, source: published.source),
                                   published.usage)
                }
                measure("screenSummaryDerivation") { _ = Self.usageSummary(current) }
                measure("currentGraphExtraction") { _ = Self.graph(current) }
                measure("currentReverseClosure") {
                    _ = Self.reverseClosure(["component_b"], graph: Self.graph(current))
                }
                try measure("combinedPlanner") {
                    let plan = try Self.plan(changes, current: current, published: published)
                    XCTAssertTrue(plan.affected.all.count > 0)
                }
                measure("fullProjection") { _ = IndexProjection(document: current) }
            }
            let planned = try Self.plan(changes, current: current, published: published)
            Self.assertOracle(planned, old: published, current: current)
            let actual = Self.actual(published.rows, Self.rows(current))
            let summary = measures.mapValues { ["p50Ms": percentile($0, 0.5), "p95Ms": percentile($0, 0.95)] }
            reports.append(["fixture": name, "components": count, "runs": 5, "timings": summary,
                            "actualChangedRows": actual.count, "plannedAffectedRows": planned.affected.all.count,
                            "impactedCurrentComponents": planned.impactedCurrent.count,
                            "impactedAllComponents": planned.impactedAll.count])
        }
        let root: [String: Any] = ["environment": "Swift 6.4 debug XCTest, macOS, in-process; no Canonical acquisition, Git, CLI, targeted projector, or publication",
                                   "fixtures": reports]
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
