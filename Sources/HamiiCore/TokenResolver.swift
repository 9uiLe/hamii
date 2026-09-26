import Foundation

public enum TokenResolver {
    public static func spacing(_ id: EntityID?, in tokens: [DesignToken]) -> Double? {
        guard let id else { return nil }
        let byID = Dictionary(tokens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current = id
        var visited = Set<EntityID>()
        while visited.insert(current).inserted, let token = byID[current], token.kind == .spacing {
            switch token.value {
            case .literal(let raw):
                guard let value = Double(raw), value.isFinite, value >= 0 else { return nil }
                return value
            case .reference(let next): current = next
            }
        }
        return nil
    }
}
