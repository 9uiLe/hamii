import Foundation

public struct InteractionStep: Equatable {
    public var from: String
    public var to: String
    public var actions: [InteractionAction]
    public var motionID: EntityID?
}

public enum InteractionEngine {
    public static func advance(_ interaction: Interaction, from state: String, event: String) -> InteractionStep? {
        guard let transition = interaction.transitions.first(where: { $0.from == state && $0.event == event }) else { return nil }
        return InteractionStep(from: state, to: transition.to, actions: transition.actions, motionID: transition.motionID)
    }
}
