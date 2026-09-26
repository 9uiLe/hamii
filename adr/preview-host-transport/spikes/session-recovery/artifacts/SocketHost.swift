// Throwaway iOS Simulator transport probe. This is not a hamii Preview Host.
import Foundation
import Network
import Observation
import SwiftUI

@MainActor @Observable
final class ProbeModel {
    var status = "Connecting"
    var latest = "No snapshot"
    private var revisions: [String: Int] = [:]
    private var connection: NWConnection?
    private var incoming = Data()
    private let queue = DispatchQueue(label: "hamii.spike.socket-host")

    func start() {
        guard connection == nil else { return }
        connect()
    }

    private func connect() {
        let socket = NWConnection(host: "127.0.0.1", port: 34123, using: .tcp)
        connection = socket
        socket.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = "Connected"
                    self.send(["kind": "hello", "schema": 1, "revisions": self.revisions], to: socket)
                    self.receive(from: socket)
                case .failed, .cancelled:
                    self.status = "Disconnected"
                    self.connection = nil
                    self.incoming = Data()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.connect() }
                default: break
                }
            }
        }
        socket.start(queue: queue)
    }

    private func receive(from socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.incoming.append(data) }
                while let newline = self.incoming.firstIndex(of: 10) {
                    let line = self.incoming.prefix(upTo: newline)
                    self.incoming.removeSubrange(...newline)
                    self.handle(Data(line), socket: socket)
                }
                if complete || error != nil {
                    socket.cancel()
                } else {
                    self.receive(from: socket)
                }
            }
        }
    }

    private func handle(_ line: Data, socket: NWConnection) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let id = message["id"] as? Int ?? -1
        let surface = message["surface"] as? String ?? ""
        let kind = message["kind"] as? String ?? ""
        let schema = message["schema"] as? Int ?? -1
        let revision = message["revision"] as? Int ?? -1
        let current = revisions[surface] ?? -1
        var reason = ""
        if schema != 1 { reason = "schemaMismatch" }
        else if surface.isEmpty { reason = "surfaceMissing" }
        else if kind == "snapshot" {
            revisions[surface] = revision
        } else if kind == "patch" {
            let base = message["baseRevision"] as? Int ?? -1
            if base != current || revision != current + 1 { reason = "needsSnapshot" }
            else { revisions[surface] = revision }
        } else { reason = "kindUnsupported" }
        if reason.isEmpty { latest = "\(surface) revision \(revision): \(message["text"] as? String ?? "")" }
        send(["kind": "ack", "id": id, "surface": surface, "accepted": reason.isEmpty,
              "revision": revisions[surface] ?? -1, "reason": reason], to: socket)
    }

    private func send(_ object: [String: Any], to socket: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        socket.send(content: data + Data([10]), completion: .contentProcessed { _ in })
    }
}

@main
struct SocketProbeApp: App {
    @State private var model = ProbeModel()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("hamii transport spike").font(.title)
                Text(model.status)
                Text(model.latest)
            }
            .padding()
            .task { model.start() }
        }
    }
}
