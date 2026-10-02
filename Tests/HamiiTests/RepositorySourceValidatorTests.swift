import Foundation
import XCTest
import HamiiCore
@testable import HamiiFormat
import HamiiIntegration
@testable import HamiiIntegrationRuntime

final class RepositorySourceValidatorTests: XCTestCase {
    private let screenID = EntityID("screen_source")
    private let profilePath = "config/profile.json"
    private let sourcePath = "Sources/Profile.swift"

    private struct Fixture {
        let directory: URL
        let hamii: URL
        let product: URL
    }

    private func fixture(source: String = "struct Profile {\n let nickname: String\n}\n",
                         locator: SwiftDirectDeclarationLocator? = nil,
                         event: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-validator-\(UUID().uuidString)")
        let hamii = directory.appendingPathComponent("hamii")
        let product = directory.appendingPathComponent("Product")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = CanonicalRepository(root: hamii)
        _ = try repository.create(name: "Source")
        let observed = try repository.observe()
        var document = observed.document
        let scope = EntityID("scope_app")
        document.scopes = [ArchitectureScope(id: scope, name: "App", parentID: nil)]
        var text = Layer(id: EntityID("layer_text"), kind: .text, name: "Nickname", text: "Nickname")
        text.textBinding = "profile.nickname"
        var children = [text]
        if event {
            var button = Layer(id: EntityID("layer_button"), kind: .button, name: "Edit", text: "Edit")
            button.emittedEvent = "tapEdit"
            children.append(button)
        }
        document.screens = [Screen(id: screenID, name: "Profile", scopeID: scope,
            root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: children))]
        document.revision += 1
        _ = try repository.commit(document, expected: observed)

        try FileManager.default.createDirectory(at: product.appendingPathComponent("config"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: product.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try git(product, "init", "-q")
        try git(product, "config", "user.name", "Source Test")
        try git(product, "config", "user.email", "source@example.invalid")
        var profile = IntegrationProfileV2(repositoryName: "Product")
        profile.sourceLocators["input:profile.nickname"] = locator ?? .init(path: sourcePath,
            enclosingKind: .structType, enclosingName: "Profile", memberKind: .storedProperty,
            memberName: "nickname")
        if event {
            profile.sourceLocators["event:tapEdit"] = .init(path: sourcePath,
                enclosingKind: .structType, enclosingName: "Profile", memberKind: .storedProperty,
                memberName: "nickname")
        }
        try JSONEncoder().encode(profile).write(to: product.appendingPathComponent(profilePath))
        try Data(source.utf8).write(to: product.appendingPathComponent(sourcePath))
        try git(product, "add", ".")
        try git(product, "commit", "-qm", "Pin profile and source")
        return Fixture(directory: directory, hamii: hamii, product: product)
    }

    private func git(_ root: URL, _ args: String...) throws {
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
    }

    private func plan(_ fixture: Fixture) throws -> RepositoryProfilePlanResult {
        try RepositoryProfileRuntime.plan(hamiiRoot: fixture.hamii, productRoot: fixture.product,
            profilePath: profilePath, screenID: screenID)
    }

    private func single(_ fixture: Fixture) throws -> RepositorySourceEvidence {
        try XCTUnwrap(plan(fixture).repositoryMappingEvidence?.first)
    }

    func testDirectDeclarationIsVerifiedFromPinnedBlobWithoutProductMutation() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let index = item.product.appendingPathComponent(".git/index")
        let beforeIndex = try Data(contentsOf: index)
        let beforeSource = try Data(contentsOf: item.product.appendingPathComponent(sourcePath))
        let result = try plan(item)
        let evidence = try XCTUnwrap(result.repositoryMappingEvidence?.first)
        XCTAssertEqual(result.receipt.profileFormatVersion, 2)
        XCTAssertEqual(evidence.mappingKey, "input:profile.nickname")
        XCTAssertEqual(evidence.status, .verified)
        XCTAssertEqual(evidence.scope, "pinnedSourceDeclaration")
        XCTAssertNotNil(evidence.sourceBlobOID)
        XCTAssertFalse(result.plan.needsResolution)
        XCTAssertEqual(try Data(contentsOf: index), beforeIndex)
        XCTAssertEqual(try Data(contentsOf: item.product.appendingPathComponent(sourcePath)), beforeSource)
        XCTAssertEqual(try RepositorySourceValidator.validate(receipt: result.receipt,
            hamiiRoot: item.hamii, productRoot: item.product), result.repositoryMappingEvidence)
    }

    func testDirectEnumCaseSupportsEventMappingWithoutBuildClaim() throws {
        let item = try fixture(source: "struct Profile { let nickname: String }\nenum ProfileAction { case editTapped }\n")
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let repository = CanonicalRepository(root: item.hamii)
        let observed = try repository.observe()
        var document = observed.document
        var button = Layer(id: EntityID("layer_edit"), kind: .button, name: "Edit", text: "Edit")
        button.emittedEvent = "editTapped"
        document.screens[0].root.children.append(button)
        document.revision += 1
        _ = try repository.commit(document, expected: observed)

        let profileFile = item.product.appendingPathComponent(profilePath)
        var profile = try IntegrationProfileFile.decodeV2(data: Data(contentsOf: profileFile))
        profile.sourceLocators["event:editTapped"] = .init(path: sourcePath,
            enclosingKind: .enumType, enclosingName: "ProfileAction",
            memberKind: .enumCase, memberName: "editTapped")
        try JSONEncoder().encode(profile).write(to: profileFile)
        try git(item.product, "add", profilePath)
        try git(item.product, "commit", "-qm", "Add event locator")

        let result = try plan(item)
        XCTAssertFalse(result.plan.needsResolution)
        let event = try XCTUnwrap(result.repositoryMappingEvidence?.first {
            $0.mappingKey == "event:editTapped"
        })
        XCTAssertEqual(event.status, .verified)
        XCTAssertEqual(event.scope, "pinnedSourceDeclaration")
    }

    func testMissingDuplicateWrongKindAndUnsupportedSourceAreFailClosed() throws {
        let cases: [(String, RepositorySourceEvidenceStatus)] = [
            ("struct Profile {\n let createdAt: String\n}\n", .missing),
            ("struct Profile {\n let nickname: String\n let nickname: String\n}\n", .ambiguous),
            ("enum Profile {\n case nickname\n}\n", .kindMismatch),
            ("#if DEBUG\nstruct Profile { let nickname: String }\n#endif\n", .unverifiable),
            ("#sourceLocation(file: \"fake.swift\", line: 100)\nstruct Profile { let nickname: String }\n", .unverifiable),
            ("struct Profile {}\nextension Profile { var nickname: String { \"a\" } }\n", .unverifiable)
        ]
        for (source, expected) in cases {
            let item = try fixture(source: source)
            defer { try? FileManager.default.removeItem(at: item.directory) }
            let result = try plan(item)
            XCTAssertEqual(result.repositoryMappingEvidence?.first?.status, expected, source)
            XCTAssertTrue(result.plan.needsResolution, source)
        }
    }

    func testInvalidLocatorAndStaleReceipt() throws {
        let bad = SwiftDirectDeclarationLocator(path: "../Profile.swift", enclosingKind: .structType,
            enclosingName: "Profile", memberKind: .storedProperty, memberName: "nickname")
        let badItem = try fixture(locator: bad)
        defer { try? FileManager.default.removeItem(at: badItem.directory) }
        XCTAssertEqual(try single(badItem).status, .invalidLocator)

        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let receipt = try plan(item).receipt
        try Data("struct Profile { let createdAt: String }\n".utf8)
            .write(to: item.product.appendingPathComponent(sourcePath))
        try git(item.product, "add", sourcePath)
        try git(item.product, "commit", "-qm", "Change source")
        XCTAssertThrowsError(try RepositorySourceValidator.validate(receipt: receipt,
            hamiiRoot: item.hamii, productRoot: item.product)) { error in
            XCTAssertEqual((error as? RepositoryProfileRuntimeError)?.reason, "staleProduct")
        }
    }

    func testDeletedTrackedSourceIsMissingAndBlocksResolution() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        try FileManager.default.removeItem(at: item.product.appendingPathComponent(sourcePath))
        try git(item.product, "add", "-u", sourcePath)
        try git(item.product, "commit", "-qm", "Delete source")
        let result = try plan(item)
        XCTAssertEqual(result.repositoryMappingEvidence?.first?.status, .missing)
        XCTAssertEqual(result.repositoryMappingEvidence?.first?.reason, "missingSourcePath")
        XCTAssertTrue(result.plan.resolutionIssues.contains {
            $0.code == .invalidMapping && $0.semanticID == "input:profile.nickname"
        })
    }

    func testStructuralStringCannotBecomeSecondSourceAuthority() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let profileFile = item.product.appendingPathComponent(profilePath)
        var profile = try IntegrationProfileFile.decodeV2(data: Data(contentsOf: profileFile))
        profile.stateMappings["profile.nickname"] = "Unrelated.target"
        try JSONEncoder().encode(profile).write(to: profileFile)
        try git(item.product, "add", profilePath)
        try git(item.product, "commit", "-qm", "Add duplicate mapping authority")
        let duplicate = try plan(item)
        XCTAssertEqual(duplicate.repositoryMappingEvidence?.first?.status, .unverifiable)
        XCTAssertEqual(duplicate.repositoryMappingEvidence?.first?.reason, "duplicateMappingAuthority")
        XCTAssertTrue(duplicate.plan.resolutionIssues.contains { $0.code == .invalidMapping })

        profile.sourceLocators.removeValue(forKey: "input:profile.nickname")
        try JSONEncoder().encode(profile).write(to: profileFile)
        try git(item.product, "add", profilePath)
        try git(item.product, "commit", "-qm", "Keep structural string only")
        let structuralOnly = try plan(item)
        XCTAssertEqual(structuralOnly.repositoryMappingEvidence?.first?.reason, "structuralValueWithoutLocator")
        XCTAssertTrue(structuralOnly.plan.resolutionIssues.contains { $0.code == .invalidMapping })

        profile.stateMappings["profile.nickname"] = " "
        try JSONEncoder().encode(profile).write(to: profileFile)
        try git(item.product, "add", profilePath)
        try git(item.product, "commit", "-qm", "Blank structural mapping")
        XCTAssertTrue(try plan(item).plan.resolutionIssues.contains { $0.code == .emptyMapping })

        profile.stateMappings.removeValue(forKey: "profile.nickname")
        try JSONEncoder().encode(profile).write(to: profileFile)
        try git(item.product, "add", profilePath)
        try git(item.product, "commit", "-qm", "Remove mapping authority")
        XCTAssertTrue(try plan(item).plan.resolutionIssues.contains { $0.code == .missingMapping })
    }

    func testContractMappingKindCannotBeDefinedByUntrustedLocator() throws {
        let item = try fixture(event: true)
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let result = try plan(item)
        XCTAssertEqual(result.repositoryMappingEvidence?.map(\.mappingKey),
            ["event:tapEdit", "input:profile.nickname"])
        XCTAssertEqual(result.repositoryMappingEvidence?.first?.status, .kindMismatch)
        XCTAssertEqual(result.repositoryMappingEvidence?.first?.reason, "mappingKindMemberKindMismatch")
        XCTAssertEqual(result.repositoryMappingEvidence?.last?.status, .verified)
        XCTAssertTrue(result.plan.resolutionIssues.contains {
            $0.code == .invalidMapping && $0.semanticID == "event:tapEdit"
        })
    }

    func testSameCommitCloneAndConcurrentProductChange() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let receipt = try plan(item).receipt
        let clone = item.directory.appendingPathComponent("clone")
        try git(item.directory, "clone", "-q", item.product.path, clone.path)
        XCTAssertEqual(try RepositorySourceValidator.validate(receipt: receipt,
            hamiiRoot: item.hamii, productRoot: clone).first?.status, .verified)
        XCTAssertThrowsError(try RepositoryProfileRuntime.plan(hamiiRoot: item.hamii,
            productRoot: item.product, profilePath: profilePath, screenID: screenID,
            beforeFinalVerification: {
                try Data("changed".utf8).write(to: item.product.appendingPathComponent(sourcePath))
            })) { error in
            XCTAssertEqual((error as? RepositoryProfileRuntimeError)?.reason, "dirtyProduct")
        }
    }
}
