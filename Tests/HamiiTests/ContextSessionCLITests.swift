import Darwin
import Foundation
import XCTest

final class ContextSessionCLITests: XCTestCase {
    func testRealProcessTransportAndInvalidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/test-context-session.py").path,
                             "--binary", root.appendingPathComponent(".build/debug/hamii").path]
        process.standardOutput = log
        process.standardError = log
        try process.run()
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); XCTFail("Context session regression timed out") }
        process.waitUntilExit()
        let result = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, result)
        XCTAssertTrue(result.contains("\"status\": \"passed\""), result)
    }
}
