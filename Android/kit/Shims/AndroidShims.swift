// Android stand-ins for the Kit parts that need Apple frameworks. build.sh links the Kit's own source
// folders next to this file, so the Kit compiles unchanged; Package.swift leaves out the Apple-only files.

// URLSession and XMLParser live in separate modules outside Apple platforms. Re-exported here so every Kit
// file sees them without its own import.
import Foundation
@_exported import FoundationNetworking
@_exported import FoundationXML

// App Attest (Support/WorkerAuth.swift) only exists on Apple devices; Android will prove itself with Play
// Integrity instead (#467). Until then requests to our servers go out without a token, like from the Simulator.
public struct WorkerAuth: Sendable {}

extension HTTPClient {
    func sendRaw(_ request: URLRequest, auth: WorkerAuth?) async throws -> Data { try await sendRaw(request) }
    func workerAuth(_ auth: WorkerAuth?) -> WorkerAuth? { auth }
}
