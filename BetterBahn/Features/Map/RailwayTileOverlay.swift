import BetterBahnKit
import MapKit
import os

/// OpenRailwayMap tiles with BetterBahn's identifying User-Agent and linked attribution in the legend.
///
/// OpenRailwayMap is run by volunteers and blocks apps that request too much (#171), so tiles are kept
/// on disk for a week, the tile size matches the 512 px "retina" PNGs the server sends (with MapKit's
/// default of 256 px an iPhone asks for about four times as many tiles), and a 403/429 pauses all
/// requests for 10 minutes instead of drawing the error as a tile.
nonisolated final class RailwayTileOverlay: MKTileOverlay, @unchecked Sendable {
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let cooldown: TimeInterval = 10 * 60

    private static let log = Logger(subsystem: "de.goldkunibert.BetterBahn", category: "railwaytiles")
    private static let blockedUntil = OSAllocatedUnfairLock<Date?>(initialState: nil)

    private static let cache = URLCache(
        memoryCapacity: 20 * 1024 * 1024,
        diskCapacity: 300 * 1024 * 1024,
        directory: URL.cachesDirectory.appending(path: "RailwayTiles", directoryHint: .isDirectory))

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Tiles are cached by hand above, with our own freshness instead of the server's few hours.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["User-Agent": HTTPClient.identifyingUserAgent]
        return URLSession(configuration: config)
    }()

    init() {
        super.init(urlTemplate: "https://tiles.openrailwaymap.org/standard/{z}/{x}/{y}.png")
        canReplaceMapContent = false
        tileSize = CGSize(width: 512, height: 512)
        maximumZ = 19
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let request = URLRequest(url: url(forTilePath: path))
        let cached = Self.cache.cachedResponse(for: request)
        if let cached, let stored = cached.userInfo?["stored"] as? Date,
           Date.now.timeIntervalSince(stored) < Self.maxAge {
            result(cached.data, nil)
            return
        }
        if Self.isBlocked {
            // Paused after a block: an outdated tile is better than none, otherwise leave the spot empty.
            result(cached?.data, cached == nil ? URLError(.resourceUnavailable) : nil)
            return
        }
        let stale = cached?.data
        nonisolated(unsafe) let completion = result
        Self.session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            if let http, let data, http.statusCode == 200,
               http.mimeType?.hasPrefix("image/") == true {
                Self.cache.storeCachedResponse(
                    CachedURLResponse(response: http, data: data, userInfo: ["stored": Date.now], storagePolicy: .allowed),
                    for: request)
                completion(data, nil)
                return
            }
            if let status = http?.statusCode, status == 403 || status == 429 {
                Self.log.error("OpenRailwayMap answered \(status), pausing tile requests")
                Self.blockedUntil.withLock { $0 = Date.now.addingTimeInterval(Self.cooldown) }
            }
            // Never draw an error page as a tile; keep the old one if there is one.
            if let stale {
                completion(stale, nil)
            } else {
                completion(nil, error ?? URLError(.badServerResponse))
            }
        }.resume()
    }

    private static var isBlocked: Bool {
        blockedUntil.withLock { $0.map { $0 > .now } ?? false }
    }
}
