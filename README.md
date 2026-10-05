# BetterBahn

An iOS app (SwiftUI) that makes travelling by train in Germany easier: journey search, departure
boards, live delays, Wagenreihung, saved journeys with Live Activities, a map of your past trips,
DB tickets in Apple Wallet and Träwelling check-ins. The app's interface is in German.

BetterBahn is a private, non-commercial project and is **not affiliated with Deutsche Bahn AG**.

## Data sources

Journeys, boards and trips come from [Transitous](https://transitous.org) (see its
[sources](https://transitous.org/sources/)). Some extras come from bahn.de (through a proxy Worker),
DB Timetables, [vagonweb.cz](https://www.vagonweb.cz) (used with permission), bahn.expert,
bahn.jetzt, [Träwelling](https://traewelling.de) and map tiles from
[OpenStreetMap](https://www.openstreetmap.org/copyright) / [OpenRailwayMap](https://www.openrailwaymap.org).
Please respect each service's terms when you build on this code.
More in [docs/transit-providers.md](docs/transit-providers.md).

## Building

Requirements: Xcode 26 and an iOS 26 device or simulator.

1. Open `BetterBahn.xcodeproj` and pick the `BetterBahn` scheme.
2. To sign with your own Apple Developer account, copy `Config/Local.xcconfig.example` to
   `Config/Local.xcconfig` (gitignored) and fill in your team ID and a bundle ID suffix.
3. Build and run.

Tests for the model and networking package: `swift test --package-path Packages/BetterBahnKit`.

The app talks to a few Cloudflare Workers in [`Cloudflare/`](Cloudflare) (privacy policy, bahn.de
proxy, Apple Wallet pass signing). They only accept the App Store build (App Attest), so a build
signed with your own team runs without the features that need them (e.g. Wagenreihung from bahn.de,
DB realtime messages, Wallet passes) unless you deploy your own Workers and point the base URLs in
`Packages/BetterBahnKit` at them. Each Worker's README explains its setup and secrets.

[docs/CODEBASE.md](docs/CODEBASE.md) is a map of the code.

## Contributing

Issues and pull requests are welcome. Please open pull requests against `prod-other`,
`prod-bugs` or `prod-features` rather than `prod`.

Found a security problem? Please don't open a public issue; see [SECURITY.md](SECURITY.md).

## License

[Mozilla Public License 2.0](LICENSE)
