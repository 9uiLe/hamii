import Foundation
import HamiiCore

/// The exact Profile, Product source, and hamii observation used to review a plan.
/// This value records evidence; its consumer verifies the referenced sources.
public struct RepositoryProfileReceipt: Codable, Equatable {
    public let receiptFormatVersion: Int
    public let productCommitOID: String
    public let profilePath: String
    public let profileBlobOID: String
    public let profileSHA256: String
    public let profileFormatVersion: Int
    public let hamiiDocumentID: EntityID
    public let hamiiDocumentRevision: Int
    public let hamiiStatePrecondition: ClientPrecondition
    public let screenID: EntityID
    public let contractSHA256: String

    public init(
        receiptFormatVersion: Int = 1,
        productCommitOID: String,
        profilePath: String,
        profileBlobOID: String,
        profileSHA256: String,
        profileFormatVersion: Int,
        hamiiDocumentID: EntityID,
        hamiiDocumentRevision: Int,
        hamiiStatePrecondition: ClientPrecondition,
        screenID: EntityID,
        contractSHA256: String
    ) {
        self.receiptFormatVersion = receiptFormatVersion
        self.productCommitOID = productCommitOID
        self.profilePath = profilePath
        self.profileBlobOID = profileBlobOID
        self.profileSHA256 = profileSHA256
        self.profileFormatVersion = profileFormatVersion
        self.hamiiDocumentID = hamiiDocumentID
        self.hamiiDocumentRevision = hamiiDocumentRevision
        self.hamiiStatePrecondition = hamiiStatePrecondition
        self.screenID = screenID
        self.contractSHA256 = contractSHA256
    }
}
