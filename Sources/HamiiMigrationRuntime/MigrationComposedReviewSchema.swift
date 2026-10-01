import Foundation

/// JSONDecoder accepts unknown fields and Foundation dictionaries erase duplicate
/// keys. A composed review is publication evidence, so its complete shape is
/// checked before typed decoding. Syntax is checked by JSONSerialization first.
enum MigrationComposedReviewSchema {
    static func validate(_ data: Data) throws {
        let raw = try JSONSerialization.jsonObject(with: data)
        try MigrationReviewUniqueKeys.validate(data, allDepths: true)
        let root = try object(raw, exactly: [
            "recordFormatVersion", "reviewID", "sourceRef", "sourceOID", "sourceTreeOID",
            "sourceCanonicalRevision", "sourceCanonicalIdentity", "sourceFormatVersion",
            "targetFormatVersion", "sourceDocumentRevision", "candidateDocumentRevision",
            "classification", "receipts", "edgeResolutionAudits", "candidateOID",
            "candidateTreeOID", "retentionRef", "changedPaths", "diffNameStatus", "diffStat",
            "validation", "indexValidation"
        ])
        for rawReceipt in try array(root["receipts"]) {
            let receipt = try object(rawReceipt, exactly: [
                "sourceVersion", "targetVersion", "edgeID", "inputIdentity", "outputIdentity",
                "classification", "resolutionDecisions", "losses"
            ])
            try validateDecisions(receipt["resolutionDecisions"])
            try validateLosses(receipt["losses"])
        }
        for rawAudit in try array(root["edgeResolutionAudits"]) {
            let audit = try object(rawAudit, exactly: ["edgeID", "manifest", "decisions", "losses"])
            let manifest = try object(audit["manifest"], exactly: [
                "formatVersion", "sourceOID", "sourceCanonicalIdentity", "sourceFormatVersion",
                "targetFormatVersion", "decisions"
            ])
            try validateDecisions(manifest["decisions"])
            try validateDecisions(audit["decisions"])
            try validateLosses(audit["losses"])
        }
        _ = try object(root["validation"], exactly: [
            "currentFormat", "canonicalSnapshotIdentity", "documentID", "documentRevision"
        ])
        _ = try object(root["indexValidation"], exactly: [
            "sourceCanonicalIdentity", "indexGenerationID", "canonicalRevision"
        ])
    }

    private static func validateDecisions(_ raw: Any?) throws {
        for entry in try array(raw) {
            let decision = try object(entry, exactly: ["item", "selectedCandidateID"])
            try item(decision["item"])
        }
    }

    private static func validateLosses(_ raw: Any?) throws {
        for entry in try array(raw) {
            let loss = try object(entry, required: [
                "item", "choiceID", "path", "historicalValue", "affectedSemantic"
            ], optional: ["entityID"])
            try item(loss["item"])
        }
    }

    private static func item(_ raw: Any?) throws {
        _ = try object(raw, required: ["code", "path", "historicalValueFingerprint"],
                       optional: ["entityID"])
    }

    private static func object(_ raw: Any?, exactly keys: Set<String>) throws -> [String: Any] {
        try object(raw, required: keys, optional: [])
    }

    private static func object(_ raw: Any?, required: Set<String>,
                               optional: Set<String>) throws -> [String: Any] {
        guard let value = raw as? [String: Any], required.isSubset(of: Set(value.keys)),
              Set(value.keys).isSubset(of: required.union(optional)) else {
            throw MigrationReviewStoreError.invalidRecord
        }
        return value
    }

    private static func array(_ raw: Any?) throws -> [Any] {
        guard let value = raw as? [Any] else { throw MigrationReviewStoreError.invalidRecord }
        return value
    }
}

/// The top-level mode is used for version dispatch without changing the
/// historical v1/v2 nested decoding contract. v3 checks every object depth.
enum MigrationReviewUniqueKeys {
    static func validate(_ data: Data, allDepths: Bool) throws {
        var scanner = Scanner(data, allDepths: allDepths)
        try scanner.validate()
    }

    private struct Scanner {
        let bytes: [UInt8]
        let allDepths: Bool
        var offset = 0

        init(_ data: Data, allDepths: Bool) {
            bytes = Array(data)
            self.allDepths = allDepths
        }

        mutating func validate() throws {
            try value(depth: 0)
            whitespace()
            guard offset == bytes.count else { throw MigrationReviewStoreError.invalidRecord }
        }

        private mutating func value(depth: Int) throws {
            guard depth < 128 else { throw MigrationReviewStoreError.invalidRecord }
            whitespace()
            guard offset < bytes.count else { throw MigrationReviewStoreError.invalidRecord }
            switch bytes[offset] {
            case 123: // {
                offset += 1
                whitespace()
                var keys = Set<String>()
                if take(125) { return }
                while true {
                    let key = try JSONDecoder().decode(String.self, from: stringToken())
                    if allDepths || depth == 0 {
                        guard keys.insert(key).inserted else { throw MigrationReviewStoreError.invalidRecord }
                    }
                    whitespace()
                    guard take(58) else { throw MigrationReviewStoreError.invalidRecord }
                    try value(depth: depth + 1)
                    whitespace()
                    if take(125) { return }
                    guard take(44) else { throw MigrationReviewStoreError.invalidRecord }
                    whitespace()
                }
            case 91: // [
                offset += 1
                whitespace()
                if take(93) { return }
                while true {
                    try value(depth: depth + 1)
                    whitespace()
                    if take(93) { return }
                    guard take(44) else { throw MigrationReviewStoreError.invalidRecord }
                }
            case 34:
                _ = try stringToken()
            default:
                while offset < bytes.count && ![UInt8(44), 93, 125, 32, 9, 10, 13].contains(bytes[offset]) {
                    offset += 1
                }
            }
        }

        private mutating func stringToken() throws -> Data {
            whitespace()
            guard take(34) else { throw MigrationReviewStoreError.invalidRecord }
            let start = offset - 1
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == 92 { // escaped next byte
                    guard offset < bytes.count else { throw MigrationReviewStoreError.invalidRecord }
                    offset += 1
                    continue
                }
                if byte == 34 { return Data(bytes[start..<offset]) }
            }
            throw MigrationReviewStoreError.invalidRecord
        }

        private mutating func whitespace() {
            while offset < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[offset]) { offset += 1 }
        }

        private mutating func take(_ byte: UInt8) -> Bool {
            guard offset < bytes.count && bytes[offset] == byte else { return false }
            offset += 1
            return true
        }
    }
}
