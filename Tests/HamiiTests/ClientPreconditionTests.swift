import Foundation
import XCTest
import HamiiApplication
import HamiiCore
import HamiiFormat

final class ClientPreconditionTests: XCTestCase {
    func testTwoClientsShareApplicationServicePrecondition() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Two Clients")
        let serviceA = ProjectService(repository: repository)
        let serviceB = ProjectService(repository: CanonicalRepository(root: root))
        let initial = try serviceA.observe()
        let first = try serviceA.mutate(.createPage(name: "A"), expectedState: initial.statePrecondition, author: .human)
        XCTAssertEqual(first.revision, 1)
        XCTAssertThrowsError(try serviceB.mutate(.createPage(name: "B"), expectedState: initial.statePrecondition, author: .agent, agent: AgentHarness(profileName: "builder"))) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
        }
        let current = try serviceB.observe()
        XCTAssertNotEqual(initial.statePrecondition, current.statePrecondition)
        XCTAssertNoThrow(try serviceB.mutate(.createPage(name: "B"), expectedState: current.statePrecondition, author: .human))
    }

    func testSameRevisionBranchSwitchRejectsOldClientAfterProcessReopen() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Branches")
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, "init", "-q")
        try commit(root, "baseline")
        let main = try gitOutput(root, "branch", "--show-current").trimmingCharacters(in: .whitespacesAndNewlines)
        try git(root, "switch", "-qc", "other")
        let otherService = ProjectService(repository: repository)
        _ = try otherService.mutate(.createPage(name: "Other"), expectedState: otherService.observe().statePrecondition, author: .human)
        try commit(root, "other page")
        try git(root, "switch", "-q", main)
        let mainService = ProjectService(repository: repository)
        _ = try mainService.mutate(.createPage(name: "Main"), expectedState: mainService.observe().statePrecondition, author: .human)
        try commit(root, "main page")
        let old = try mainService.observe()
        let epochBeforeSwitch = try Data(contentsOf: root.appendingPathComponent(".hamii/client-observation-epoch"))
        try git(root, "switch", "-q", "other")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".hamii/client-observation-epoch")), epochBeforeSwitch)
        // A new Repository instance represents a restarted CLI process.
        let reopened = ProjectService(repository: CanonicalRepository(root: root))
        let current = try reopened.observe()
        XCTAssertEqual(old.document.revision, current.document.revision)
        XCTAssertNotEqual(old.statePrecondition, current.statePrecondition)
        XCTAssertThrowsError(try reopened.mutate(.createPage(name: "Old session"), expectedState: old.statePrecondition, author: .human)) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testRestartAndMissingEpochFailClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Restart")
        let before = try repository.observe()
        let reopened = CanonicalRepository(root: root)
        XCTAssertEqual(try reopened.observe().statePrecondition, before.statePrecondition)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".hamii/client-observation-epoch"))
        let after = try reopened.observe()
        XCTAssertNotEqual(before.statePrecondition, after.statePrecondition)
        let service = ProjectService(repository: reopened)
        XCTAssertThrowsError(try service.mutate(.createPage(name: "Old"), expectedState: before.statePrecondition, author: .human))
        try Data("corrupt\n".utf8).write(to: root.appendingPathComponent(".hamii/client-observation-epoch"))
        XCTAssertThrowsError(try reopened.observe())
    }

    func testAgentProfileChangeInvalidatesObservedState() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Profiles")
        let before = try repository.observe()
        let profileURL = root.appendingPathComponent("hamii-agent-profiles.json")
        let original = try String(contentsOf: profileURL, encoding: .utf8)
        try original.replacingOccurrences(of: "\"builder\"", with: "\"builderChanged\"")
            .write(to: profileURL, atomically: true, encoding: .utf8)
        let after = try repository.observe()
        XCTAssertNotEqual(before.statePrecondition, after.statePrecondition)
        let service = ProjectService(repository: repository)
        XCTAssertThrowsError(try service.mutate(.createPage(name: "Old profile state"), expectedState: before.statePrecondition, author: .human)) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hamii-client-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func commit(_ root: URL, _ message: String) throws {
        try git(root, "add", "-A")
        try git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", message)
    }

    private func git(_ root: URL, _ args: String...) throws { _ = try gitOutput(root, args) }

    private func gitOutput(_ root: URL, _ args: String...) throws -> String { try gitOutput(root, args) }

    private func gitOutput(_ root: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Git", code: Int(process.terminationStatus)) }
        return String(decoding: output, as: UTF8.self)
    }
}
