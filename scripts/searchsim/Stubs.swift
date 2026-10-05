import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// Linux stand-in for the App Attest code, which needs Apple frameworks.
public struct WorkerAuth: Sendable {}
extension HTTPClient {
    func sendRaw(_ request: URLRequest, auth: WorkerAuth?) async throws -> Data { try await sendRaw(request) }
    func workerAuth(_ auth: WorkerAuth?) -> WorkerAuth? { auth }
}
