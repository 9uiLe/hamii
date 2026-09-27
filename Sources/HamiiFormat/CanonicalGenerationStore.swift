import Darwin
import Foundation

/// A coordinated worktree transition sequence. It is distinct from the
/// content identity, client observation token, and published Index generation.
public struct CanonicalGeneration: Equatable, Hashable {
    public let lineage: UUID
    public let value: UInt64
    public init(lineage: UUID, value: UInt64) { self.lineage = lineage; self.value = value }
    public var serialized: String { "\(lineage.uuidString.lowercased()):\(value)" }
    public init?(serialized: String) {
        let parts = serialized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let lineage = UUID(uuidString: String(parts[0])),
              let value = UInt64(parts[1]) else { return nil }
        self.init(lineage: lineage, value: value)
    }
}

public enum CanonicalGenerationError: Error, CustomStringConvertible {
    case missing
    case corrupt
    case pending
    case unknownState
    case generationExhausted

    public var description: String {
        switch self {
        case .missing: return "Canonical generation record is missing; verified bootstrap is required"
        case .corrupt: return "Canonical generation record is corrupt; the worktree remains unverified"
        case .pending: return "Canonical generation transition is pending recovery"
        case .unknownState: return "Canonical generation cannot be matched to a validated snapshot"
        case .generationExhausted: return "Canonical generation counter is exhausted"
        }
    }
}

public struct StableCanonicalGeneration: Equatable {
    public let generation: CanonicalGeneration
    public let snapshotIdentity: CanonicalSnapshotIdentity
}

/// Persistent state only. Its caller must already hold the worktree's
/// WorktreeCoordinator lock; this type never acquires a second flock.
public struct CanonicalGenerationStore {
    public let root: URL
    private var recordURL: URL { root.appendingPathComponent(".hamii/canonical-generation.json") }

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func readStable() throws -> StableCanonicalGeneration {
        let record = try read()
        guard record.phase == .stable else { throw CanonicalGenerationError.pending }
        guard let identity = CanonicalSnapshotIdentity(rawValue: record.snapshotIdentity ?? "") else {
            throw CanonicalGenerationError.corrupt
        }
        guard let lineage = record.lineageID else { throw CanonicalGenerationError.corrupt }
        return StableCanonicalGeneration(generation: CanonicalGeneration(lineage: lineage, value: record.generation), snapshotIdentity: identity)
    }

    /// This is an explicit, slow bootstrap from a validated coordinated
    /// snapshot. A missing record must never be interpreted as generation 1
    /// merely because a project exists on disk.
    public func bootstrapVerified(_ snapshot: CanonicalSnapshot) throws -> StableCanonicalGeneration {
        guard !FileManager.default.fileExists(atPath: recordURL.path) else { return try readStable() }
        let stable = StableCanonicalGeneration(generation: CanonicalGeneration(lineage: UUID(), value: 1), snapshotIdentity: snapshot.identity)
        try write(Record.stable(generation: stable.generation, identity: snapshot.identity.rawValue))
        return stable
    }

    @discardableResult
    public func beginPending(old: StableCanonicalGeneration, expectedNewIdentity: CanonicalSnapshotIdentity?,
                             operationID: UUID = UUID()) throws -> UUID {
        guard try readStable() == old else { throw CanonicalGenerationError.unknownState }
        guard old.generation.value < UInt64.max else { throw CanonicalGenerationError.generationExhausted }
        try write(Record.pending(operationID: operationID, old: old,
                                 proposed: old.generation.value + 1, expectedNewIdentity: expectedNewIdentity))
        return operationID
    }

    @discardableResult
    public func reconcile(_ snapshot: CanonicalSnapshot, expectedOperationID: UUID? = nil,
                          validatedNewIdentity: CanonicalSnapshotIdentity? = nil) throws -> StableCanonicalGeneration {
        let record = try read()
        if record.phase == .stable { return try requireMatchingStable(snapshot) }
        guard record.phase == .pending, let operationID = record.operationID, let lineage = record.lineageID,
              expectedOperationID == nil || expectedOperationID == operationID,
              let oldIdentity = CanonicalSnapshotIdentity(rawValue: record.oldSnapshotIdentity ?? ""),
              let proposed = record.proposedGeneration, proposed == record.generation + 1 else {
            throw CanonicalGenerationError.unknownState
        }
        if snapshot.identity == oldIdentity {
            let stable = StableCanonicalGeneration(generation: CanonicalGeneration(lineage: lineage, value: record.generation), snapshotIdentity: oldIdentity)
            try write(Record.stable(generation: stable.generation, identity: oldIdentity.rawValue))
            return stable
        }
        let expected = CanonicalSnapshotIdentity(rawValue: record.expectedNewIdentity ?? "") ?? validatedNewIdentity
        guard snapshot.identity == expected else { throw CanonicalGenerationError.unknownState }
        let stable = StableCanonicalGeneration(generation: CanonicalGeneration(lineage: lineage, value: proposed), snapshotIdentity: snapshot.identity)
        try write(Record.stable(generation: stable.generation, identity: snapshot.identity.rawValue))
        return stable
    }

    public func requireMatchingStable(_ snapshot: CanonicalSnapshot) throws -> StableCanonicalGeneration {
        let stable = try readStable()
        guard stable.snapshotIdentity == snapshot.identity else { throw CanonicalGenerationError.unknownState }
        return stable
    }

    /// Use only after the surrounding operation has independently validated
    /// its new branch/commit and the resulting coordinated snapshot.
    @discardableResult
    public func finalizeVerifiedTransition(_ snapshot: CanonicalSnapshot,
                                           expectedOperationID: UUID? = nil) throws -> StableCanonicalGeneration {
        let record = try read()
        if record.phase == .stable { return try requireMatchingStable(snapshot) }
        guard record.phase == .pending, let operationID = record.operationID, let lineage = record.lineageID,
              expectedOperationID == nil || expectedOperationID == operationID,
              let proposed = record.proposedGeneration, proposed == record.generation + 1 else {
            throw CanonicalGenerationError.unknownState
        }
        let stable = StableCanonicalGeneration(generation: CanonicalGeneration(lineage: lineage, value: proposed), snapshotIdentity: snapshot.identity)
        try write(Record.stable(generation: stable.generation, identity: snapshot.identity.rawValue))
        return stable
    }

    private func read() throws -> Record {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { throw CanonicalGenerationError.missing }
        guard let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL)),
              record.formatVersion == 1 else { throw CanonicalGenerationError.corrupt }
        return record
    }

    private func write(_ record: Record) throws {
        try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        try sync(recordURL)
        try sync(recordURL.deletingLastPathComponent())
    }

    private func sync(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private struct Record: Codable {
        enum Phase: String, Codable { case stable, pending }
        let formatVersion: Int
        let phase: Phase
        let lineageID: UUID?
        let generation: UInt64
        let snapshotIdentity: String?
        let operationID: UUID?
        let proposedGeneration: UInt64?
        let oldSnapshotIdentity: String?
        let expectedNewIdentity: String?

        static func stable(generation: CanonicalGeneration, identity: String) -> Record {
            Record(formatVersion: 1, phase: .stable, lineageID: generation.lineage, generation: generation.value, snapshotIdentity: identity,
                   operationID: nil, proposedGeneration: nil, oldSnapshotIdentity: nil, expectedNewIdentity: nil)
        }

        static func pending(operationID: UUID, old: StableCanonicalGeneration, proposed: UInt64,
                            expectedNewIdentity: CanonicalSnapshotIdentity?) -> Record {
            Record(formatVersion: 1, phase: .pending, lineageID: old.generation.lineage,
                   generation: old.generation.value, snapshotIdentity: nil,
                   operationID: operationID, proposedGeneration: proposed,
                   oldSnapshotIdentity: old.snapshotIdentity.rawValue,
                   expectedNewIdentity: expectedNewIdentity?.rawValue)
        }
    }
}
