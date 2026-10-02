import Foundation
import XCTest
import HamiiCore
@testable import HamiiFormat
import HamiiIntegration
@testable import HamiiIntegrationRuntime

final class RepositoryBuildMembershipValidatorTests: XCTestCase {
    private let screenID = EntityID("screen_build_membership")
    private let profilePath = "config/profile.json"
    private let sourcePath = "Sources/Profile.swift"
    private let selection = RepositoryBuildSelection(projectPath: "Product.xcodeproj", scheme: "Product",
        rootTarget: "App", ownerTarget: "App", module: "App", configuration: "Debug",
        sdk: "iphonesimulator", destination: "generic/platform=iOS Simulator", architecture: "arm64")

    private struct Fixture {
        let directory: URL
        let hamii: URL
        let product: URL
    }

    private func fixture(v2: Bool = true, includeAge: Bool = false,
                         source: String = "struct Profile {\n let nickname: String\n let age: Int\n}\n",
                         locatorPath: String = "Sources/Profile.swift") throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-membership-validator-\(UUID().uuidString)")
        let hamii = directory.appendingPathComponent("hamii")
        let product = directory.appendingPathComponent("Product")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = CanonicalRepository(root: hamii)
        _ = try repository.create(name: "Membership")
        let observed = try repository.observe()
        var document = observed.document
        let scope = EntityID("scope_app")
        document.scopes = [ArchitectureScope(id: scope, name: "App", parentID: nil)]
        var nickname = Layer(id: EntityID("layer_nickname"), kind: .text, name: "Nickname", text: "Nickname")
        nickname.textBinding = "profile.nickname"
        var children = [nickname]
        if includeAge {
            var age = Layer(id: EntityID("layer_age"), kind: .text, name: "Age", text: "Age")
            age.textBinding = "profile.age"
            children.append(age)
        }
        document.screens = [Screen(id: screenID, name: "Profile", scopeID: scope,
            root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: children))]
        document.revision += 1
        _ = try repository.commit(document, expected: observed)

        try FileManager.default.createDirectory(at: product.appendingPathComponent("config"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: product.appendingPathComponent("Sources"),
            withIntermediateDirectories: true)
        try git(product, "init", "-q")
        try git(product, "config", "user.name", "Membership Test")
        try git(product, "config", "user.email", "membership@example.invalid")
        let profileData: Data
        if v2 {
            var profile = IntegrationProfileV2(repositoryName: "Product")
            profile.sourceLocators["input:profile.nickname"] = .init(path: locatorPath,
                enclosingKind: .structType, enclosingName: "Profile",
                memberKind: .storedProperty, memberName: "nickname")
            if includeAge {
                profile.sourceLocators["input:profile.age"] = .init(path: sourcePath,
                    enclosingKind: .structType, enclosingName: "Profile",
                    memberKind: .storedProperty, memberName: "age")
            }
            profileData = try JSONEncoder().encode(profile)
        } else {
            var profile = IntegrationProfile(repositoryName: "Product")
            profile.stateMappings["profile.nickname"] = "Profile.nickname"
            profileData = try JSONEncoder().encode(profile)
        }
        try profileData.write(to: product.appendingPathComponent(profilePath))
        try Data(source.utf8).write(to: product.appendingPathComponent(sourcePath))
        try git(product, "add", ".")
        try git(product, "commit", "-qm", "Pin profile and source")
        return Fixture(directory: directory, hamii: hamii, product: product)
    }

    private func git(_ root: URL, _ args: String...) throws { _ = try gitOutput(root, args) }

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
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitTest", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func receipt(_ item: Fixture) throws -> RepositoryProfileReceipt {
        try RepositoryProfileRuntime.plan(hamiiRoot: item.hamii, productRoot: item.product,
            profilePath: profilePath, screenID: screenID).receipt
    }

    private func validate(_ item: Fixture, receipt: RepositoryProfileReceipt) throws -> [RepositoryBuildEvidence] {
        try RepositoryBuildMembershipValidator.validate(receipt: receipt,
            hamiiRoot: item.hamii, productRoot: item.product, selection: selection)
    }

    private func assertNoPositive(_ evidence: [RepositoryBuildEvidence],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(evidence.contains { $0.status == .selectedBuildMember }, file: file, line: line)
        XCTAssertTrue(evidence.allSatisfy { $0.status == .unverifiable }, file: file, line: line)
    }

    func testVerifiedV2SourceStillCannotEstablishSelectedBuildMembership() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let plan = try RepositoryProfileRuntime.plan(hamiiRoot: item.hamii, productRoot: item.product,
            profilePath: profilePath, screenID: screenID)
        XCTAssertEqual(plan.repositoryMappingEvidence?.first?.status, .verified)
        let result = try validate(item, receipt: plan.receipt)
        XCTAssertEqual(result.count, 1)
        let evidence = try XCTUnwrap(result.first)
        XCTAssertEqual(evidence.mappingKey, "input:profile.nickname")
        XCTAssertEqual(evidence.status, .unverifiable)
        XCTAssertEqual(evidence.reason, "protectedBuildAcquisitionUnavailable")
        XCTAssertNil(evidence.scope)
        XCTAssertEqual(evidence.productCommitOID, plan.receipt.productCommitOID)
        XCTAssertEqual(evidence.sourcePath, sourcePath)
        XCTAssertEqual(evidence.sourceBlobOID, plan.repositoryMappingEvidence?.first?.sourceBlobOID)
        XCTAssertEqual(evidence.requestedSelection, selection)
        XCTAssertNil(evidence.resolvedSelection)
        XCTAssertNil(evidence.compilerExecutable)
        XCTAssertNil(evidence.invocationID)
        XCTAssertNil(evidence.inventorySHA256)
        assertNoPositive(result)
    }

    func testV1ReceiptHasNoBuildMembershipEvidence() throws {
        let item = try fixture(v2: false)
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let pinned = try receipt(item)
        XCTAssertEqual(pinned.profileFormatVersion, 1)
        let result = try validate(item, receipt: pinned)
        XCTAssertTrue(result.isEmpty)
        assertNoPositive(result)
    }

    func testUnverifiedSourceNeverGetsProtectedAcquisitionReason() throws {
        let cases: [(String, String)] = [
            ("Sources/Missing.swift", "struct Profile {\n let nickname: String\n}\n"),
            (sourcePath, "struct Profile {\n let other: String\n}\n"),
            (sourcePath, "#if DEBUG\nstruct Profile { let nickname: String }\n#endif\n")
        ]
        for (path, source) in cases {
            let item = try fixture(source: source, locatorPath: path)
            defer { try? FileManager.default.removeItem(at: item.directory) }
            let pinned = try receipt(item)
            let result = try validate(item, receipt: pinned)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.status, .unverifiable)
            XCTAssertEqual(result.first?.reason, "sourceNotVerified", "\(path): \(source)")
            assertNoPositive(result)
        }
    }

    func testStaleProductAndHamiiReceiptsPropagateExistingFailures() throws {
        let productChanged = try fixture()
        defer { try? FileManager.default.removeItem(at: productChanged.directory) }
        let productReceipt = try receipt(productChanged)
        try Data("struct Profile { let replacement: String }\n".utf8)
            .write(to: productChanged.product.appendingPathComponent(sourcePath))
        try git(productChanged.product, "add", sourcePath)
        try git(productChanged.product, "commit", "-qm", "Change pinned Product source")
        XCTAssertThrowsError(try validate(productChanged, receipt: productReceipt)) {
            XCTAssertEqual($0 as? RepositoryProfileRuntimeError,
                RepositoryProfileRuntimeError(category: "conflict", reason: "staleProduct"))
        }

        let hamiiChanged = try fixture()
        defer { try? FileManager.default.removeItem(at: hamiiChanged.directory) }
        let hamiiReceipt = try receipt(hamiiChanged)
        let repository = CanonicalRepository(root: hamiiChanged.hamii)
        let observed = try repository.observe()
        var document = observed.document
        document.name = "Changed"
        document.revision += 1
        _ = try repository.commit(document, expected: observed)
        XCTAssertThrowsError(try validate(hamiiChanged, receipt: hamiiReceipt)) {
            XCTAssertEqual($0 as? RepositoryProfileRuntimeError,
                RepositoryProfileRuntimeError(category: "conflict", reason: "staleHamiiObservation"))
        }
    }

    func testMultipleMappingsAreSortedAndDoNotMutateProductOrHamii() throws {
        let item = try fixture(includeAge: true)
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let pinned = try receipt(item)
        let headBefore = try gitOutput(item.product, ["rev-parse", "HEAD"])
        let refBefore = try gitOutput(item.product, ["symbolic-ref", "HEAD"])
        let statusBefore = try gitOutput(item.product, ["status", "--porcelain=v2", "--untracked-files=all"])
        let indexBefore = try Data(contentsOf: item.product.appendingPathComponent(".git/index"))
        let profileBefore = try Data(contentsOf: item.product.appendingPathComponent(profilePath))
        let sourceBefore = try Data(contentsOf: item.product.appendingPathComponent(sourcePath))
        let canonicalBefore = try canonicalJSON(item.hamii)

        let first = try validate(item, receipt: pinned)
        let second = try validate(item, receipt: pinned)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.mappingKey), ["input:profile.age", "input:profile.nickname"])
        XCTAssertEqual(first.map(\.reason), ["protectedBuildAcquisitionUnavailable",
            "protectedBuildAcquisitionUnavailable"])
        assertNoPositive(first)
        XCTAssertEqual(try gitOutput(item.product, ["rev-parse", "HEAD"]), headBefore)
        XCTAssertEqual(try gitOutput(item.product, ["symbolic-ref", "HEAD"]), refBefore)
        XCTAssertEqual(try gitOutput(item.product, ["status", "--porcelain=v2", "--untracked-files=all"]), statusBefore)
        XCTAssertEqual(try Data(contentsOf: item.product.appendingPathComponent(".git/index")), indexBefore)
        XCTAssertEqual(try Data(contentsOf: item.product.appendingPathComponent(profilePath)), profileBefore)
        XCTAssertEqual(try Data(contentsOf: item.product.appendingPathComponent(sourcePath)), sourceBefore)
        XCTAssertEqual(try canonicalJSON(item.hamii), canonicalBefore)
    }

    private func canonicalJSON(_ root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw NSError(domain: "CanonicalTest", code: 1)
        }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }
}
