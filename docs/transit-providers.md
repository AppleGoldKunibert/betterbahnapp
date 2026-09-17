# Transit providers

Research checked 2026-09-17.

Transitous now supplies station search, journeys, departure/arrival boards and trip details. The existing direct bahn.de client remains a station-search fallback and optional coach-formation helper. There is currently **no full journey/board fallback configured**. The retired DB REST implementation, DTOs, fixtures and URL setting have been removed. The `dbRest` source value remains solely to decode saved data: stations are resolved through Transitous; provider-specific old trip IDs and pagination tokens require a new search.

## Replacement options

| Candidate | Coverage and fit | Work required / limitation |
| --- | --- | --- |
| Separately hosted [MOTIS](https://github.com/motis-project/motis) | Recommended next step for a full fallback; same API family as Transitous, routing and realtime feeds | Provision a server, maintain Germany GTFS/GTFS-RT feeds, verify API versions and monitor feed freshness. Independent hosting protects against a Transitous outage, but shared feeds can still fail together. |
| Official [DB Timetables](https://developers.deutschebahn.com/db-api-marketplace/apis/product/timetables) | Useful independent fallback for station boards and delay/cancellation updates | Register and subscribe; the published free plan lists 60 requests/minute. Build a backend credential proxy and merge scheduled XML data with changes. Does not replace journey planning. |
| [ÖBB HAFAS profile](https://github.com/public-transport/hafas-client/tree/main/p/oebb) | Candidate for German train coverage, suggested by the [DB REST maintainers](https://v6.db.transport.rest/) | Needs a hosted adapter, access/coverage evaluation and live tests. Not verified as a dependable production endpoint here. |
| [db-vendo-client](https://github.com/public-transport/db-vendo-client) / another DB REST wrapper | Broad functionality, but not recommended for resilient failover | Its maintainers explicitly warn of unreliable access and blocking; another wrapper keeps the same underlying DB dependency. |

No candidate above has been deployed or enabled. A separate MOTIS adapter needs its own data-source identity: station IDs, trip IDs and page cursors must not be assumed interchangeable across instances. `CombinedProvider` retains optional provider injection, cooldown and source-aware routing; pagination stays on its originating provider rather than silently restarting on failure.

## Transitous integration

Use only the [documented public endpoint](https://transitous.org/api/), not staging or internal load-balancer hosts as fallbacks. Requests include application/version/contact identification, and Settings links to Transitous data sources and OpenStreetMap attribution. Transitous is a best-effort community service with an open-source, noncommercial usage policy; coordinate routing/resource usage with its operators as described there. Realtime coverage depends on the contributing feeds.

## Validation

Run `swift test --package-path Packages/BetterBahnKit`. Migration tests cover saved stations, provider selection, pagination, retired IDs, cancellation, retries and request identification. All 40 package tests and the iOS simulator app/widget build passed after this migration. A live Transitous Berlin Hbf geocode request also returned HTTP 200 with station results. Other network behavior is tested with URLProtocol fixtures; this spot check does not establish a service-level guarantee.
