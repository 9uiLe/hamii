import Foundation
import HamiiApplication
import HamiiCore

public enum ManagedGitError: Error, CustomStringConvertible {
    case invalidWorktree
    case dirtyWorktree
    case invalidBranch(String)
    case changedDuringTransition
    case commandFailed(String)

    public var description: String {
        switch self {
        case .invalidWorktree: return "Project root must be the Git worktree root"
        case .dirtyWorktree: return "Managed Git switch requires a clean worktree"
        case .invalidBranch(let name): return "Invalid or unavailable branch: \(name)"
        case .changedDuringTransition: return "Git state changed during managed transition; recovery is required"
        case .commandFailed(let detail): return "Managed Git command failed: \(detail)"
        }
    }
}

enum ManagedGitStep: Equatable { case pending, switched, validated }

/// A Git adapter that participates in WorktreeCoordinator. A pending marker
/// prevents normal Canonical access after an interrupted switch. Recovery
/// accepts only a complete, clean source or target branch state.
public final class ManagedGit {
    public let root: URL
    private let coordinator: WorktreeCoordinator
    private let repository: CanonicalRepository
    private let hook: ((ManagedGitStep) throws -> Void)?

    public init(root: URL) {
        self.root = root.standardizedFileURL
        coordinator = WorktreeCoordinator(root: self.root)
        repository = CanonicalRepository(root: self.root)
        hook = nil
    }

    init(root: URL, hook: @escaping (ManagedGitStep) throws -> Void) {
        self.root = root.standardizedFileURL
        coordinator = WorktreeCoordinator(root: self.root)
        repository = CanonicalRepository(root: self.root)
        self.hook = hook
    }

    public func switchBranch(_ targetBranch: String, expectedState: ClientPrecondition) throws -> ProjectObservation {
        try coordinator.withExclusive {
            try coordinator.requireReady()
            try requireWorktreeRoot()
            let current = try repository.observeDuringManagedGitTransition()
            guard current.statePrecondition == expectedState else { throw AuthoringError.staleState }
            try requireCleanWorktree()
            let sourceBranch = try branch()
            guard sourceBranch != targetBranch else { return current }
            guard (try? git("check-ref-format", "--branch", targetBranch)) != nil,
                  let targetHead = try? git("rev-parse", "--verify", "refs/heads/\(targetBranch)^{commit}") else {
                throw ManagedGitError.invalidBranch(targetBranch)
            }
            let transition = ManagedGitTransition(sourceBranch: sourceBranch, sourceHead: try head(), targetBranch: targetBranch, targetHead: targetHead)
            try coordinator.beginGitTransition(transition)
            try hook?(.pending)
            do {
                _ = try git("switch", "--no-guess", targetBranch)
                try hook?(.switched)
                guard try branch() == targetBranch, try head() == targetHead else { throw ManagedGitError.changedDuringTransition }
                try requireCleanWorktree()
                let result = try repository.observeDuringManagedGitTransition()
                try hook?(.validated)
                try coordinator.finishGitTransition()
                return result
            } catch let error as CanonicalError {
                // A completed but semantically invalid switch can be restored
                // without discarding edits because the source was clean.
                // Unknown or partially changed states keep the pending gate.
                if (try? branch()) == targetBranch, (try? head()) == targetHead,
                   (try? requireCleanWorktree()) != nil,
                   (try? git("switch", "--no-guess", sourceBranch)) != nil,
                   (try? branch()) == sourceBranch, (try? head()) == transition.sourceHead,
                   (try? repository.observeDuringManagedGitTransition()) != nil {
                    try coordinator.finishGitTransition()
                }
                throw error
            }
        }
    }

    public func recover() throws -> ProjectObservation {
        try coordinator.withExclusive {
            try requireWorktreeRoot()
            guard let pending = try coordinator.pendingGitTransition() else {
                return try repository.observeDuringManagedGitTransition()
            }
            try requireCleanWorktree()
            let currentBranch = try branch()
            let currentHead = try head()
            guard (currentBranch == pending.sourceBranch && currentHead == pending.sourceHead) ||
                  (currentBranch == pending.targetBranch && currentHead == pending.targetHead) else {
                throw ManagedGitError.changedDuringTransition
            }
            do {
                let result = try repository.observeDuringManagedGitTransition()
                try coordinator.finishGitTransition()
                return result
            } catch let error as CanonicalError {
                guard currentBranch == pending.targetBranch,
                      (try? git("switch", "--no-guess", pending.sourceBranch)) != nil,
                      (try? branch()) == pending.sourceBranch,
                      (try? head()) == pending.sourceHead else { throw error }
                try requireCleanWorktree()
                let restored = try repository.observeDuringManagedGitTransition()
                try coordinator.finishGitTransition()
                return restored
            }
        }
    }

    private func requireWorktreeRoot() throws {
        let actual = try git("rev-parse", "--show-toplevel")
        guard URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else {
            throw ManagedGitError.invalidWorktree
        }
    }

    private func requireCleanWorktree() throws {
        guard try git("status", "--porcelain=v1", "--untracked-files=all").isEmpty else {
            throw ManagedGitError.dirtyWorktree
        }
    }

    private func branch() throws -> String { try git("symbolic-ref", "--quiet", "--short", "HEAD") }
    private func head() throws -> String { try git("rev-parse", "HEAD") }

    @discardableResult private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw ManagedGitError.commandFailed(message) }
        return message
    }
}
