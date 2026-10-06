import SwiftUI

/// Settings → Datenquellen: every service the app gets data from, with the attribution their terms ask for
/// (Transitous sources, OSM + OpenRailwayMap with links, DB Timetables under CC BY 4.0).
struct DataSourcesView: View {
    struct Source: Identifiable {
        let name: String
        let usage: String
        let url: URL
        var license: (title: String, url: URL)?
        var id: String { name }
    }

    static let sources: [Source] = [
        Source(name: "Transitous", usage: "Verbindungen, Abfahrten, Fahrten und Bahnhofssuche",
               url: URL(string: "https://transitous.org")!,
               license: ("Quellen der Fahrplandaten", URL(string: "https://transitous.org/sources/")!)),
        Source(name: "Deutsche Bahn – DB Timetables", usage: "Echtzeitdaten und Meldungen",
               url: URL(string: "https://developers.deutschebahn.com/db-api-marketplace/apis/product/timetables")!,
               license: ("Lizenz: CC BY 4.0", URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!)),
        Source(name: "Deutsche Bahn – Infrastrukturdaten der DB InfraGO", usage: "RIL100-Codes der Bahnhöfe",
               url: URL(string: "https://mobilithek.info/offers/922109165921083392")!,
               license: ("Lizenz: CC BY 4.0", URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!)),
        Source(name: "bahn.de", usage: "Wagenreihung, Zusatzhalte, Gleise und Zugnamen",
               url: URL(string: "https://www.bahn.de")!),
        Source(name: "vagonweb.cz", usage: "Geplante Wagenreihungen und Zugtypen, mit Erlaubnis von vagonweb",
               url: URL(string: "https://www.vagonweb.cz")!),
        Source(name: "bahn.expert", usage: "Zugtypen", url: URL(string: "https://bahn.expert")!),
        Source(name: "bahn.jetzt", usage: "Zugpositionen auf der Karte", url: URL(string: "https://bahn.jetzt")!),
        Source(name: "Träwelling", usage: "Check-ins", url: URL(string: "https://traewelling.de")!),
        Source(name: "OpenStreetMap", usage: "Kartendaten des Schienennetzes, © OpenStreetMap-Mitwirkende",
               url: URL(string: "https://www.openstreetmap.org/copyright")!),
        Source(name: "OpenRailwayMap", usage: "Kartenkacheln des Schienennetzes",
               url: URL(string: "https://www.openrailwaymap.org")!),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Link(source.name, destination: source.url)
                            .font(.body.weight(.semibold))
                        Text(source.usage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let license = source.license {
                            Link(license.title, destination: license.url)
                                .font(.footnote)
                        }
                    }
                    .padding(.vertical, 2)
                    // Two links in one row: without this, a tap anywhere opens both.
                    .buttonStyle(.borderless)
                }
            } footer: {
                Text("Karten: Apple Karten. BetterBahn ist ein privates Projekt und steht in keiner Verbindung zur Deutschen Bahn AG oder den anderen Diensten.")
            }
        }
        .navigationTitle("Datenquellen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { DataSourcesView() }
}
