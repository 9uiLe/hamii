import HamiiCore

/// Bounded capability detail for AI context. This conveys assessment, not
/// mutation or approval authority.
public struct ContextSurfaceCapabilityDetail: Codable, Equatable {
    public let surfaceID: EntityID
    public let screenID: EntityID
    public let profile: CapabilityProfile
    public let requirementCount: Int
    public let capabilityAllowed: Bool
    public let losses: ContextBoundedList<CapabilityLoss>
    public let previewReady: Bool
    public let previewDiagnostics: ContextBoundedList<Diagnostic>

    public init(_ assessment: SurfaceCapabilityAssessment) {
        surfaceID = assessment.surfaceID
        screenID = assessment.screenID
        profile = assessment.lossReport.profile
        requirementCount = assessment.lossReport.items.count
        capabilityAllowed = assessment.lossReport.allowed
        losses = ContextBoundedList(assessment.lossReport.items.filter { $0.loss != .none })
        previewReady = assessment.previewPlan.canPreview
        previewDiagnostics = ContextBoundedList(assessment.previewPlan.diagnostics)
    }
}

extension ProjectContextProjection {
    static func surfaceCapabilityDetail(
        _ observed: ProjectObservation,
        surfaceID: EntityID
    ) throws -> ContextResponse<ContextSurfaceCapabilityDetail> {
        let assessment: SurfaceCapabilityAssessment
        do {
            assessment = try SurfaceCapabilityAssessmentService.assess(
                document: observed.document, surfaceID: surfaceID
            )
        } catch let error as SurfaceCapabilityAssessmentError {
            switch error {
            case .surfaceNotFound(let id), .screenNotFound(let id), .targetNotFound(let id):
                throw AuthoringError.notFound(id.rawValue)
            }
        }
        return ContextResponse(
            observation: ContextObservation(observed),
            payload: ContextSurfaceCapabilityDetail(assessment)
        )
    }
}
