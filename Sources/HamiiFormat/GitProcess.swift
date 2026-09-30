import Foundation

package struct GitProcessResult {
    package let status: Int32
    package let stdout: Data
    package let stderr: Data
}

/// Keeps Git's machine-readable output separate from diagnostic output.
/// All three streams are serviced concurrently so a full pipe cannot stall Git.
package enum GitProcess {
    package static func run(at worktree: URL, _ arguments: [String], input: Data? = nil,
                            executable: URL = URL(fileURLWithPath: "/usr/bin/git")) throws -> GitProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", worktree.path] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input == nil ? nil : Pipe()
        if let stdin { process.standardInput = stdin }

        let result = StreamResult()
        let group = DispatchGroup()
        try process.run()
        group.enter()
        DispatchQueue.global().async {
            result.setStdout(stdout.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            result.setStderr(stderr.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        if let stdin, let input {
            group.enter()
            DispatchQueue.global().async {
                do { try stdin.fileHandleForWriting.write(contentsOf: input) }
                catch { result.setInputError(error) }
                try? stdin.fileHandleForWriting.close()
                group.leave()
            }
        }
        group.wait()
        process.waitUntilExit()
        return try result.value(status: process.terminationStatus)
    }
}

private final class StreamResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var inputError: Error?

    func setStdout(_ value: Data) { lock.lock(); defer { lock.unlock() }; stdout = value }
    func setStderr(_ value: Data) { lock.lock(); defer { lock.unlock() }; stderr = value }
    func setInputError(_ value: Error) { lock.lock(); defer { lock.unlock() }; inputError = value }

    func value(status: Int32) throws -> GitProcessResult {
        lock.lock()
        defer { lock.unlock() }
        if let inputError { throw inputError }
        return GitProcessResult(status: status, stdout: stdout, stderr: stderr)
    }
}
