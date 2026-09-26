import Foundation
import XCTest
import HamiiCore
@testable import HamiiFormat

/// Controlled evidence for the coordinated-writer part of CanonicalSnapshot.
final class CanonicalSnapshotSpikeTests: XCTestCase {
    private final class ProbeState: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        let readerStarted = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        var writerError: Error?
        var readerResult: Result<Document, Error>?
        var old: Document?
        var new: Document?
        var root: URL?
        var writer: CanonicalRepository?
    }

    func testHamiiReaderWaitsForCoordinatedSaveAndLoadsWholeNewDocument() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        let old = try repository.create(name: "Snapshot lock")
        var new = old
        new.pages = [Page(id: EntityID("page_new"), name: "New")]
        new.revision = 1
        let state = ProbeState()
        state.old = old
        state.new = new
        state.root = path
        let writer = CanonicalRepository(root: path) { step in
            if case .applied("pages/page_new.json") = step {
                state.entered.signal()
                guard state.release.wait(timeout: .now() + 5) == .success else {
                    throw CocoaError(.fileReadUnknown)
                }
            }
        }
        state.writer = writer
        DispatchQueue.global().async {
            do { try state.writer!.save(state.new!, expected: state.old!) }
            catch { state.writerError = error }
            state.writerDone.signal()
        }
        XCTAssertEqual(state.entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            state.readerStarted.signal()
            state.readerResult = Result { try CanonicalRepository(root: state.root!).load() }
            state.readerDone.signal()
        }
        XCTAssertEqual(state.readerStarted.wait(timeout: .now() + 5), .success)
        let blockedDuringPartialSave = state.readerDone.wait(timeout: .now() + .milliseconds(150)) == .timedOut
        state.release.signal()
        XCTAssertTrue(blockedDuringPartialSave)
        XCTAssertEqual(state.writerDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(state.readerDone.wait(timeout: .now() + 5), .success)
        XCTAssertNil(state.writerError)
        XCTAssertEqual(try state.readerResult?.get(), new)
        if let path = ProcessInfo.processInfo.environment["HAMII_SNAPSHOT_SPIKE_RESULT"] {
            let result: [String: Any] = [
                "barrier": "after pages/page_new.json applied, before hamii.json applied",
                "readerBlockedFor150Ms": blockedDuringPartialSave,
                "readerLoadedWholeNewDocumentAfterRelease": try state.readerResult?.get() == new,
                "scope": "one hamii-owned save/load interleaving; external writers do not honor .hamii/write.lock",
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
