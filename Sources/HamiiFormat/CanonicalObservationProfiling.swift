import Foundation

/// Package-internal measurement only. These samples do not participate in
/// Canonical identity, coordination, validation, or recovery decisions.
package enum CanonicalObservationStage: String, Codable {
    case transactionRecovery
    case readyGate
    case stableGenerationRead
    case snapshotAcquisition
    case manifestRead
    case directoryEnumeration
    case entityBytesRead
    case entityDecode
    case documentValidation
    case assetIntegrityValidation
    case agentProfilesReadValidation
    case canonicalPathEnumerationAndSymlinkCheck
    case identityBytesRead
    case identityHash
    case canonicalRootFileChecks
    case folderExistenceChecks
    case contentsOfDirectory
    case jsonFiltering
    case rootBasedURLReconstruction
    case symlinkResourceValueChecks
    case pathSorting
}

package struct CanonicalObservationMeasurement: Codable {
    package let stage: CanonicalObservationStage
    package let detail: String?
    package let milliseconds: Double
    package let bytes: Int?
    package let pathCount: Int?
    package let folderCount: Int?

    package init(stage: CanonicalObservationStage, detail: String? = nil,
                 milliseconds: Double, bytes: Int? = nil,
                 pathCount: Int? = nil, folderCount: Int? = nil) {
        self.stage = stage
        self.detail = detail
        self.milliseconds = milliseconds
        self.bytes = bytes
        self.pathCount = pathCount
        self.folderCount = folderCount
    }
}

typealias CanonicalObservationRecorder = (CanonicalObservationMeasurement) -> Void

@inline(__always)
func measureCanonical<T>(_ stage: CanonicalObservationStage, detail: String? = nil,
                         recorder: CanonicalObservationRecorder?, _ operation: () throws -> T) rethrows -> T {
    guard let recorder else { return try operation() }
    let started = ProcessInfo.processInfo.systemUptime
    defer {
        recorder(CanonicalObservationMeasurement(stage: stage, detail: detail,
            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000))
    }
    return try operation()
}
