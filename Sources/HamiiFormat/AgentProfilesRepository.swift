import Foundation
import HamiiApplication

public struct AgentProfilesDocument: Codable {
    public var formatVersion: Int
    public var profiles: [AgentHarness]
    public init(profiles: [AgentHarness]) {
        formatVersion = 1
        self.profiles = profiles
    }
}

public enum AgentProfileError: Error, CustomStringConvertible {
    case unsupportedFormat(Int)
    case unknownProfile(String)
    case duplicateProfile(String)
    public var description: String {
        switch self {
        case .unsupportedFormat(let version): return "Unsupported Agent Harness format \(version)"
        case .unknownProfile(let name): return "Unknown Agent profile: \(name)"
        case .duplicateProfile(let name): return "Duplicate Agent profile: \(name)"
        }
    }
}

public struct AgentProfilesRepository {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func createDefault() throws {
        let url = root.appendingPathComponent("hamii-agent-profiles.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let profiles = AgentProfilesDocument(profiles: [
            AgentHarness(profileName: "builder"),
            AgentHarness(profileName: "reviewer", maximumMutations: 0)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        var data = try encoder.encode(profiles)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    public func profile(named name: String) throws -> AgentHarness {
        guard let profile = try profiles().first(where: { $0.profileName == name }) else { throw AgentProfileError.unknownProfile(name) }
        return profile
    }

    public func profiles() throws -> [AgentHarness] {
        let url = root.appendingPathComponent("hamii-agent-profiles.json")
        return try Self.decodeProfiles(from: Data(contentsOf: url))
    }

    static func decodeProfiles(from bytes: Data) throws -> [AgentHarness] {
        let document = try JSONDecoder().decode(AgentProfilesDocument.self, from: bytes)
        guard document.formatVersion == 1 else { throw AgentProfileError.unsupportedFormat(document.formatVersion) }
        let names = document.profiles.map(\.profileName)
        if let duplicate = names.first(where: { name in names.filter { $0 == name }.count > 1 }) {
            throw AgentProfileError.duplicateProfile(duplicate)
        }
        return document.profiles
    }
}
