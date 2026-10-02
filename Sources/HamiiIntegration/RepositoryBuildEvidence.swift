import Foundation

/// The caller's explicit Xcode project selection. The build adapter must resolve
/// these values from the executed build; a requested value alone proves nothing.
public struct RepositoryBuildSelection: Codable, Equatable, Sendable {
    public let projectPath: String
    public let scheme: String
    public let rootTarget: String
    public let ownerTarget: String
    public let module: String
    public let configuration: String
    public let sdk: String
    public let destination: String
    public let architecture: String

    public init(projectPath: String, scheme: String, rootTarget: String,
                ownerTarget: String, module: String, configuration: String,
                sdk: String, destination: String, architecture: String) {
        self.projectPath = projectPath
        self.scheme = scheme
        self.rootTarget = rootTarget
        self.ownerTarget = ownerTarget
        self.module = module
        self.configuration = configuration
        self.sdk = sdk
        self.destination = destination
        self.architecture = architecture
    }
}

public enum RepositoryBuildEvidenceStatus: String, Codable, Equatable, Sendable {
    case selectedBuildMember
    case missingFromSelection
    case mismatchedSource
    case ambiguous
    case unverifiable
    case staleProduct
}

/// Additive file-input evidence. Even a positive result does not establish that
/// the named declaration was active, type-correct, or used at runtime.
public struct RepositoryBuildEvidence: Codable, Equatable, Sendable {
    public let mappingKey: String
    public let status: RepositoryBuildEvidenceStatus
    public let scope: String?
    public let reason: String?
    public let productCommitOID: String?
    public let sourcePath: String?
    public let sourceBlobOID: String?
    public let requestedSelection: RepositoryBuildSelection?
    public let resolvedSelection: RepositoryBuildSelection?
    public let compilerExecutable: String?
    public let compilerVersion: String?
    public let normalizedArgumentsSHA256: String?
    public let invocationID: String?
    public let inventorySHA256: String?

    public init(mappingKey: String, status: RepositoryBuildEvidenceStatus,
                scope: String? = nil, reason: String? = nil,
                productCommitOID: String? = nil, sourcePath: String? = nil,
                sourceBlobOID: String? = nil,
                requestedSelection: RepositoryBuildSelection? = nil,
                resolvedSelection: RepositoryBuildSelection? = nil,
                compilerExecutable: String? = nil, compilerVersion: String? = nil,
                normalizedArgumentsSHA256: String? = nil,
                invocationID: String? = nil, inventorySHA256: String? = nil) {
        self.mappingKey = mappingKey
        self.status = status
        self.scope = scope
        self.reason = reason
        self.productCommitOID = productCommitOID
        self.sourcePath = sourcePath
        self.sourceBlobOID = sourceBlobOID
        self.requestedSelection = requestedSelection
        self.resolvedSelection = resolvedSelection
        self.compilerExecutable = compilerExecutable
        self.compilerVersion = compilerVersion
        self.normalizedArgumentsSHA256 = normalizedArgumentsSHA256
        self.invocationID = invocationID
        self.inventorySHA256 = inventorySHA256
    }
}
