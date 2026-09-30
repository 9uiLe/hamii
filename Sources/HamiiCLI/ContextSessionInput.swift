import Darwin
import CoreFoundation
import Foundation
import HamiiApplication
import HamiiCore

enum ContextSessionInputError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { switch self { case .usage(let message): message } }
}

enum ContextSessionRequest {
    case layer(screen: EntityID, layer: EntityID)
    case resources(scope: EntityID, kind: ContextResourceKind, matching: String?, limit: Int)
    case component(scope: EntityID, component: EntityID)
    case token(scope: EntityID, token: EntityID)
    case close

    static func decode(_ data: Data) throws -> Self {
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ContextSessionInputError.usage("Request must be a JSON object")
            }
            object = value
        } catch {
            throw ContextSessionInputError.usage("Request must be a valid JSON object")
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty else {
                throw ContextSessionInputError.usage("Request requires nonempty \(key)")
            }
            return value
        }
        let op = try string("op")
        let fields: Set<String>
        switch op {
        case "layer": fields = ["op", "screenID", "layerID"]
        case "resources": fields = ["op", "consumerScopeID", "kind", "matching", "limit"]
        case "component": fields = ["op", "consumerScopeID", "componentID"]
        case "token": fields = ["op", "consumerScopeID", "tokenID"]
        case "close": fields = ["op"]
        default: throw ContextSessionInputError.usage("Unknown context session operation")
        }
        guard Set(object.keys).isSubset(of: fields) else {
            throw ContextSessionInputError.usage("Unknown field for \(op) request")
        }
        switch op {
        case "layer": return .layer(screen: EntityID(try string("screenID")), layer: EntityID(try string("layerID")))
        case "component": return .component(scope: EntityID(try string("consumerScopeID")), component: EntityID(try string("componentID")))
        case "token": return .token(scope: EntityID(try string("consumerScopeID")), token: EntityID(try string("tokenID")))
        case "resources":
            guard let kind = ContextResourceKind(rawValue: try string("kind")) else {
                throw ContextSessionInputError.usage("Resource kind must be component, token or asset")
            }
            var limit = 32
            if let value = object["limit"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      (1...100).contains(number.doubleValue), number.doubleValue.rounded() == number.doubleValue else {
                    throw ContextSessionInputError.usage("Resource limit must be an integer in 1...100")
                }
                limit = number.intValue
            }
            let matching: String?
            if let value = object["matching"] {
                guard let text = value as? String else { throw ContextSessionInputError.usage("matching must be a string") }
                matching = text
            } else { matching = nil }
            return .resources(scope: EntityID(try string("consumerScopeID")), kind: kind, matching: matching, limit: limit)
        default: return .close
        }
    }
}

/// Holds at most one bounded line plus a 4 KiB input chunk. Oversized lines
/// are discarded through their newline before the next request is read.
final class ContextSessionLineReader {
    enum Line { case bytes(Data), oversized }
    static let maximumLineBytes = 64 * 1024
    private let input: FileHandle
    private var chunk: [UInt8] = []
    private var offset = 0

    init(input: FileHandle) { self.input = input }

    func next() throws -> Line? {
        var line = Data()
        var oversized = false
        while true {
            if offset == chunk.count {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(input.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                chunk = Array(buffer.prefix(count))
                offset = 0
                if chunk.isEmpty {
                    return oversized ? .oversized : line.isEmpty ? nil : .bytes(line)
                }
            }
            let byte = chunk[offset]
            offset += 1
            if byte == 0x0A { return oversized ? .oversized : .bytes(line) }
            if !oversized {
                if line.count == Self.maximumLineBytes { oversized = true; line.removeAll(keepingCapacity: false) }
                else { line.append(byte) }
            }
        }
    }
}
