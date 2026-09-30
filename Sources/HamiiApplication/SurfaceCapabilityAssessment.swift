import HamiiCore

/// A read-only assessment of one explicitly selected AppSurface in one observed Document.
/// Capability loss and Preview readiness remain separate results.
public struct SurfaceCapabilityAssessment {
    public let surfaceID: EntityID
    public let screenID: EntityID
    public let targetID: EntityID
    public let lossReport: CapabilityLossReport
    public let previewPlan: TargetPlan
}

public enum SurfaceCapabilityAssessmentError: Error, Equatable {
    case surfaceNotFound(EntityID)
    case screenNotFound(EntityID)
    case targetNotFound(EntityID)
}

public enum SurfaceCapabilityAssessmentService {
    /// Uses the caller's exact Document observation; it never re-reads the repository.
    public static func assess(
        document: Document,
        surfaceID: EntityID,
        approvedApproximationKeys: Set<CapabilityKey> = []
    ) throws -> SurfaceCapabilityAssessment {
        guard let surface = document.pages.lazy.flatMap(\.surfaces).first(where: { $0.id == surfaceID }) else {
            throw SurfaceCapabilityAssessmentError.surfaceNotFound(surfaceID)
        }
        guard let screen = document.screens.first(where: { $0.id == surface.screenID }) else {
            throw SurfaceCapabilityAssessmentError.screenNotFound(surface.screenID)
        }
        guard let target = document.targets.first(where: { $0.id == surface.targetID }) else {
            throw SurfaceCapabilityAssessmentError.targetNotFound(surface.targetID)
        }
        return SurfaceCapabilityAssessment(
            surfaceID: surface.id,
            screenID: screen.id,
            targetID: target.id,
            lossReport: NativePreviewCapabilityAnalysis.report(
                screen: screen,
                document: document,
                surface: surface,
                target: target,
                approvedApproximationKeys: approvedApproximationKeys
            ),
            previewPlan: TargetPlanner.plan(
                surface: surface,
                document: document,
                approvedApproximationKeys: approvedApproximationKeys
            )
        )
    }
}
