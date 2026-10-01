import Foundation
import XCTest
@testable import HamiiFormat

final class MigrationCurrentV3CLITests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func historicalProject(_ fixture: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-v3-cli-migration-\(UUID().uuidString)")
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Tests/Fixtures/\(fixture)"), to: root)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try GitCommand.run(at: root, ["init", "-q"])
        _ = try GitCommand.run(at: root, ["checkout", "-q", "-b", "main"])
        _ = try GitCommand.run(at: root, ["add", "."])
        _ = try GitCommand.run(at: root,
            ["-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "historical"])
        return root
    }

    private func cli(_ root: URL, _ arguments: String...) throws -> (Int32, [String: Any]) {
        let executable = repositoryRoot.appendingPathComponent(".build/out/Products/Debug/hamii")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--project", root.path, "--json"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            "CLI output: \(String(decoding: bytes, as: UTF8.self))")
        return (process.terminationStatus, json)
    }

    func testHistoricalV1AndV2ReachCurrentV3OnlyThroughReviewedCLIPath() throws {
        for (fixture, expectedPath) in [
            ("format-v1-safe-project", ["1->2", "2->3"]),
            ("format-v2-starter", ["2->3"])
        ] {
            let root = try historicalProject(fixture)
            defer { try? FileManager.default.removeItem(at: root) }

            let (beforeStatus, before) = try cli(root, "inspect")
            XCTAssertNotEqual(beforeStatus, 0, fixture)
            XCTAssertEqual(before["ok"] as? Bool, false, fixture)

            let (planStatus, planned) = try cli(root, "migrate", "plan")
            XCTAssertEqual(planStatus, 0, fixture)
            let plan = try XCTUnwrap(planned["migration"] as? [String: Any])
            XCTAssertEqual(plan["state"] as? String, "migrationAvailable", fixture)
            XCTAssertEqual(plan["targetDocumentFormatVersion"] as? Int, 3, fixture)

            let (prepareStatus, prepared) = try cli(root, "migrate", "prepare")
            XCTAssertEqual(prepareStatus, 0, fixture)
            let review = try XCTUnwrap(prepared["migrationReview"] as? [String: Any])
            XCTAssertEqual(review["recordFormatVersion"] as? Int, 3, fixture)
            XCTAssertEqual(review["edgePath"] as? [String], expectedPath, fixture)
            XCTAssertEqual((review["receipts"] as? [[String: Any]])?.count, expectedPath.count, fixture)
            let reviewID = try XCTUnwrap(review["reviewID"] as? String)
            let sourceOID = try XCTUnwrap(review["sourceOID"] as? String)
            let candidateOID = try XCTUnwrap(review["candidateOID"] as? String)
            XCTAssertEqual(try GitCommand.run(at: root, ["rev-parse", "HEAD"]), sourceOID)
            XCTAssertEqual(try GitCommand.run(at: root,
                ["rev-list", "--parents", "-n", "1", candidateOID]),
                "\(candidateOID) \(sourceOID)", fixture)

            let (publishStatus, published) = try cli(root, "migrate", "publish", reviewID, sourceOID, candidateOID)
            XCTAssertEqual(publishStatus, 0, fixture)
            XCTAssertEqual(published["ok"] as? Bool, true, fixture)
            XCTAssertEqual(try GitCommand.run(at: root, ["rev-parse", "HEAD"]), candidateOID)

            let (inspectStatus, inspected) = try cli(root, "inspect")
            XCTAssertEqual(inspectStatus, 0, fixture)
            let document = try XCTUnwrap(inspected["document"] as? [String: Any])
            let versions = try XCTUnwrap(document["versions"] as? [String: Any])
            XCTAssertEqual(versions["document"] as? Int, 3, fixture)
            let scopes = try XCTUnwrap(document["scopes"] as? [[String: Any]])
            let scope = try XCTUnwrap((scopes.first?["id"] as? [String: Any])?["rawValue"] as? String)
            let (validateStatus, validated) = try cli(root, "validate")
            XCTAssertEqual(validateStatus, 0, fixture)
            XCTAssertEqual(validated["ok"] as? Bool, true, fixture)
            let (queryStatus, queried) = try cli(root, "query", "components", scope, "badge")
            XCTAssertEqual(queryStatus, 0, fixture)
            XCTAssertEqual(queried["ok"] as? Bool, true, fixture)
        }
    }
}
