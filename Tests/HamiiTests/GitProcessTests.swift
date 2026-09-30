import Foundation
import XCTest
@testable import HamiiFormat

final class GitProcessTests: XCTestCase {
    private func script(_ body: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-git-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-git")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }

    func testSuccessfulMachineOutputDoesNotContainDiagnostics() throws {
        let fixture = try script("printf 'machine-data'; printf 'warning-text' >&2")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try GitProcess.run(at: fixture.directory, ["status"], executable: fixture.executable)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data("machine-data".utf8))
        XCTAssertEqual(result.stderr, Data("warning-text".utf8))
    }

    func testBinaryStdinAndBothLargeOutputStreamsDoNotDeadlock() throws {
        let fixture = try script("head -c 131072 /dev/zero >&2 & cat; wait")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = Data(repeating: 0, count: 262_144) + Data([1, 0, 2, 0, 3])
        let result = try GitProcess.run(at: fixture.directory, ["check-attr"], input: input,
                                        executable: fixture.executable)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, input)
        XCTAssertEqual(result.stderr, Data(repeating: 0, count: 131_072))
    }

    func testFailedGitKeepsDiagnosticSeparateFromMachineOutput() throws {
        let fixture = try script("printf 'partial-data'; printf 'fatal-detail' >&2; exit 7")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try GitProcess.run(at: fixture.directory, ["status"], executable: fixture.executable)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, Data("partial-data".utf8))
        XCTAssertEqual(result.stderr, Data("fatal-detail".utf8))
    }

    func testManagedGitCommandRejectsNonzeroWithDiagnostic() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-git-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try GitCommand.runData(at: directory, ["hamii-invalid-subcommand"])) { error in
            guard case ManagedGitError.commandFailed(let diagnostic) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(diagnostic.contains("hamii-invalid-subcommand"))
        }
    }

    func testManagedGitReadsRealGitDataWithoutDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-git-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try GitCommand.run(at: directory, ["init", "-q"])
        let topLevel = try GitCommand.run(at: directory, ["rev-parse", "--show-toplevel"])
        XCTAssertTrue(topLevel.hasSuffix("/" + directory.lastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: topLevel))
        try Data("content".utf8).write(to: directory.appendingPathComponent("page.json"))
        XCTAssertEqual(try GitCommand.run(at: directory, ["status", "--porcelain=v1", "--untracked-files=all"]),
                       "?? page.json")
    }
}
