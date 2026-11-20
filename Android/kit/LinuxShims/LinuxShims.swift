// Linux stand-ins for test-linux.sh: URLSession and XMLParser live in separate modules outside Apple
// platforms, and App Attest (Support/WorkerAuth.swift) only exists on Apple devices.
import Foundation
@_exported import FoundationNetworking
@_exported import FoundationXML

public struct WorkerAuth: Sendable {}

extension HTTPClient {
    func sendRaw(_ request: URLRequest, auth: WorkerAuth?) async throws -> Data { try await sendRaw(request) }
    func workerAuth(_ auth: WorkerAuth?) -> WorkerAuth? { auth }
}
