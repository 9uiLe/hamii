import Darwin
import Foundation
import HamiiFormat
import HamiiIntegration

public enum RepositorySourceEvidenceStatus: String, Codable, Equatable {
    case verified, missing, ambiguous, invalidLocator, kindMismatch, unverifiable
}

/// Evidence about an explicitly written declaration in one pinned Product blob.
/// `verified` never asserts Product build membership or runtime behavior.
public struct RepositorySourceEvidence: Codable, Equatable {
    public let mappingKey: String
    public let status: RepositorySourceEvidenceStatus
    public let scope: String?
    public let reason: String?
    public let locator: SwiftDirectDeclarationLocator?
    public let sourceBlobOID: String?
    public let line: Int?

    public init(mappingKey: String, status: RepositorySourceEvidenceStatus,
                scope: String? = nil, reason: String? = nil,
                locator: SwiftDirectDeclarationLocator? = nil,
                sourceBlobOID: String? = nil, line: Int? = nil) {
        self.mappingKey = mappingKey
        self.status = status
        self.scope = scope
        self.reason = reason
        self.locator = locator
        self.sourceBlobOID = sourceBlobOID
        self.line = line
    }
}

public enum RepositorySourceValidator {
    /// Replays the receipt through the unified v2 planner before returning evidence.
    /// This path has the same pre/post Product and final hamii observation checks.
    public static func validate(receipt: RepositoryProfileReceipt,
                                hamiiRoot: URL, productRoot: URL) throws -> [RepositorySourceEvidence] {
        let result = try RepositoryProfileRuntime.verify(receipt: receipt,
                                                          hamiiRoot: hamiiRoot, productRoot: productRoot)
        guard let evidence = result.repositoryMappingEvidence else {
            throw RepositoryProfileRuntimeError(category: "contract", reason: "invalidReceipt")
        }
        return evidence
    }

    static func inspect(mappingKey: String, locator: SwiftDirectDeclarationLocator,
                        productRoot: URL, commitOID: String) -> RepositorySourceEvidence {
        func result(_ status: RepositorySourceEvidenceStatus, _ reason: String? = nil,
                    blob: String? = nil, line: Int? = nil) -> RepositorySourceEvidence {
            RepositorySourceEvidence(mappingKey: mappingKey, status: status,
                scope: status == .verified ? "pinnedSourceDeclaration" : nil,
                reason: reason, locator: locator, sourceBlobOID: blob, line: line)
        }
        guard safePath(locator.path), validIdentifier(locator.enclosingName),
              validIdentifier(locator.memberName) else {
            return result(.invalidLocator, "malformedLocator")
        }
        let tree: Data
        do {
            tree = try GitCommand.runData(at: productRoot,
                ["ls-tree", "-r", "--full-tree", "-z", commitOID, "--", locator.path])
        } catch { return result(.unverifiable, "gitTreeUnavailable") }
        let rows = tree.split(separator: 0)
        if rows.isEmpty { return result(.missing, "missingSourcePath") }
        guard rows.count == 1,
              let tab = rows[0].firstIndex(of: UInt8(ascii: "\t")),
              let path = String(bytes: rows[0][rows[0].index(after: tab)...], encoding: .utf8),
              path == locator.path,
              let metadata = String(bytes: rows[0][..<tab], encoding: .utf8) else {
            return result(.invalidLocator, "missingOrNonExactTreePath")
        }
        let fields = metadata.split(separator: " ")
        guard fields.count == 3, ["100644", "100755"].contains(String(fields[0])), fields[1] == "blob" else {
            return result(.invalidLocator, "nonRegularTreeEntry")
        }
        let oid = String(fields[2])
        let sizeData: Data
        do { sizeData = try GitCommand.runData(at: productRoot, ["cat-file", "-s", oid]) }
        catch { return result(.unverifiable, "gitBlobUnavailable", blob: oid) }
        guard let sizeText = String(data: sizeData, encoding: .utf8),
              let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              size <= 512 * 1024 else {
            return result(.unverifiable, "sourceTooLarge", blob: oid)
        }
        let bytes: Data
        do { bytes = try GitCommand.runData(at: productRoot, ["cat-file", "blob", oid]) }
        catch { return result(.unverifiable, "gitBlobUnavailable", blob: oid) }
        guard bytes.count <= 512 * 1024, let source = String(data: bytes, encoding: .utf8) else {
            return result(.unverifiable, "sourceTooLargeOrInvalidUTF8", blob: oid)
        }
        // No build condition is selected by this source-only validator.
        // Reject a whole file containing conditional compilation rather than
        // mistakenly accepting a declaration from an inactive branch.
        if source.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#sourceLocation") }) {
            return result(.unverifiable, "sourceLocationDirective", blob: oid)
        }
        if source.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#if") }) {
            return result(.unverifiable, "conditionalCompilation", blob: oid)
        }
        guard let nodes = SwiftDirectSyntax.parse(bytes) else {
            return result(.unverifiable, "swiftParseUnavailable", blob: oid)
        }
        let nominalKind: String
        switch locator.enclosingKind {
        case .structType: nominalKind = "struct_decl"
        case .classType: nominalKind = "class_decl"
        case .enumType: nominalKind = "enum_decl"
        }
        let containers = nodes.filter { $0.name == locator.enclosingName &&
            ["struct_decl", "class_decl", "enum_decl", "extension_decl"].contains($0.kind) }
        if containers.contains(where: { $0.indent != 2 || $0.kind == "extension_decl" }) {
            return result(.unverifiable, "extensionOrNestedEnclosing", blob: oid)
        }
        let exactContainers = containers.filter { $0.kind == nominalKind }
        if exactContainers.count > 1 { return result(.ambiguous, "duplicateEnclosing", blob: oid) }
        guard let container = exactContainers.first else {
            return result(containers.isEmpty ? .missing : .kindMismatch,
                          containers.isEmpty ? "missingEnclosing" : "wrongEnclosingKind", blob: oid)
        }
        let lines = source.components(separatedBy: "\n")
        if SwiftDirectSyntax.hasNearbyAttribute(lines, at: container.start) {
            return result(.unverifiable, "attributedOrMacroEnclosing", blob: oid)
        }
        let members = nodes.filter { node in
            ["var_decl", "enum_element_decl", "func_decl"].contains(node.kind) &&
            node.name.split(separator: "(", maxSplits: 1).first.map(String.init) == locator.memberName &&
            node.indent == container.indent + 2 &&
            node.start >= container.start && node.end <= container.end
        }
        if members.count > 1 { return result(.ambiguous, "multipleDirectMembers", blob: oid) }
        guard let member = members.first else { return result(.missing, "missingMember", blob: oid) }
        let expected = locator.memberKind == .storedProperty ? "var_decl" : "enum_element_decl"
        guard member.kind == expected else { return result(.kindMismatch, "wrongMemberKind", blob: oid) }
        if locator.memberKind == .enumCase && locator.enclosingKind != .enumType {
            return result(.kindMismatch, "enumCaseInNonEnum", blob: oid)
        }
        if SwiftDirectSyntax.hasNearbyAttribute(lines, at: member.start) {
            return result(.unverifiable, "attributedOrMacroMember", blob: oid)
        }
        if member.kind == "var_decl" && member.hasAccessor {
            return result(.unverifiable, "computedOrObservedProperty", blob: oid)
        }
        return result(.verified, blob: oid, line: member.start)
    }

    private static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), path.hasSuffix(".swift"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }
}

private struct SwiftSyntaxNode {
    let indent: Int
    let kind: String
    let start: Int
    let end: Int
    let name: String
    let hasAccessor: Bool
}

/// Uses Swift's syntax parser only. Its accepted AST shape is intentionally
/// narrower than Swift itself; an unrecognized dump fails closed.
private enum SwiftDirectSyntax {
    static func parse(_ bytes: Data) -> [SwiftSyntaxNode]? {
        let process = Process()
        // Use the selected toolchain on PATH, matching SwiftPM/CI rather than
        // silently switching to the host Xcode compiler.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc", "-frontend", "-dump-parse", "-"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return nil }
        let group = DispatchGroup()
        let capture = SyntaxOutputCapture()
        group.enter()
        DispatchQueue.global().async {
            capture.read(output.fileHandleForReading, isError: false)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            capture.read(errors.fileHandleForReading, isError: true)
            group.leave()
        }
        do { try input.fileHandleForWriting.write(contentsOf: bytes) }
        catch {
            try? input.fileHandleForWriting.close()
            abort(process, readers: group)
            return nil
        }
        try? input.fileHandleForWriting.close()
        if group.wait(timeout: .now() + 10) == .timedOut {
            abort(process, readers: group)
            return nil
        }
        process.waitUntilExit()
        let captured = capture.value()
        guard process.terminationStatus == 0, !captured.overflow,
              let text = String(data: captured.output, encoding: .utf8),
              let diagnostic = String(data: captured.error, encoding: .utf8),
              !diagnostic.contains("error:"), text.hasPrefix("(source_file ") else { return nil }
        let expression = #"^([ ]*)\((struct_decl|class_decl|enum_decl|extension_decl|var_decl|enum_element_decl|func_decl)\b.*?range=\[[^\]]+?:(\d+):\d+ - line:(\d+):\d+\] (?:unbound )?\"([^\"\n]+)\""#
        guard let regex = try? NSRegularExpression(pattern: expression) else { return nil }
        let lines = text.components(separatedBy: "\n")
        var nodes: [SwiftSyntaxNode] = []
        for (offset, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 6,
                  let indentation = Range(match.range(at: 1), in: line),
                  let kindRange = Range(match.range(at: 2), in: line),
                  let startRange = Range(match.range(at: 3), in: line),
                  let endRange = Range(match.range(at: 4), in: line),
                  let nameRange = Range(match.range(at: 5), in: line),
                  let start = Int(line[startRange]), let end = Int(line[endRange]) else { continue }
            let indent = line[indentation].count
            let accessor = String(line[kindRange]) == "var_decl" &&
                lines.dropFirst(offset + 1).prefix(while: { $0.prefix(while: { $0 == " " }).count > indent })
                    .contains(where: { $0.contains("(accessor_decl ") })
            nodes.append(SwiftSyntaxNode(indent: indent, kind: String(line[kindRange]),
                start: start, end: end, name: String(line[nameRange]), hasAccessor: accessor))
        }
        // A changed frontend dump format must not turn unseen declarations
        // into a source-verified absence or a falsely direct declaration.
        for line in lines where line.contains("_decl ") && line.contains("range=") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("(struct_decl ") || trimmed.hasPrefix("(class_decl ") ||
               trimmed.hasPrefix("(enum_decl ") || trimmed.hasPrefix("(extension_decl ") ||
               trimmed.hasPrefix("(var_decl ") || trimmed.hasPrefix("(enum_element_decl ") ||
               trimmed.hasPrefix("(func_decl ") {
                guard regex.firstMatch(in: line,
                    range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil else { return nil }
            }
        }
        return nodes
    }

    private static func abort(_ process: Process, readers: DispatchGroup) {
        // A compiler that ignores SIGTERM must not turn a bounded source
        // evidence check into an indefinitely blocked integration plan.
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        _ = readers.wait(timeout: .now() + 1)
        process.waitUntilExit()
    }

    static func hasNearbyAttribute(_ lines: [String], at oneBasedLine: Int) -> Bool {
        guard oneBasedLine > 0, oneBasedLine <= lines.count else { return true }
        if lines[oneBasedLine - 1].trimmingCharacters(in: .whitespaces).hasPrefix("@") { return true }
        let lower = max(0, oneBasedLine - 5)
        for index in stride(from: oneBasedLine - 2, through: lower, by: -1) {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@") { return true }
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
            break
        }
        return false
    }
}

private final class SyntaxOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    private var overflow = false
    func read(_ handle: FileHandle, isError: Bool) {
        while true {
            let next = handle.readData(ofLength: 64 * 1024)
            if next.isEmpty { return }
            lock.lock()
            if isError {
                if error.count + next.count <= 1024 * 1024 { error.append(next) }
                else { overflow = true }
            } else {
                if output.count + next.count <= 16 * 1024 * 1024 { output.append(next) }
                else { overflow = true }
            }
            lock.unlock()
        }
    }
    func value() -> (output: Data, error: Data, overflow: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (output, error, overflow)
    }
}
