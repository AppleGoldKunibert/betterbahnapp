import SwiftUI

/// Settings → Datenquellen: every service the app gets data from, with the attribution their terms ask for
/// (Transitous sources, OSM + OpenRailwayMap with links, DB Timetables and Open-Meteo under CC BY 4.0, operator logos).
struct DataSourcesView: View {
    struct Source: Identifiable {
        let name: String
        let usage: String
        let url: URL
        var license: (title: String, url: URL)?
        var id: String { name }
    }

    static let sources: [Source] = [
        Source(name: "Transitous", usage: String(localized: "Verbindungen, Abfahrten, Fahrten und Bahnhofssuche"),
               url: URL(string: "https://transitous.org")!,
               license: (String(localized: "Quellen der Fahrplandaten"), URL(string: "https://transitous.org/sources/")!)),
        Source(name: "Deutsche Bahn – DB Timetables", usage: String(localized: "Echtzeitdaten und Meldungen"),
               url: URL(string: "https://developers.deutschebahn.com/db-api-marketplace/apis/product/timetables")!,
               license: (String(localized: "Lizenz: CC BY 4.0"), URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!)),
        Source(name: String(localized: "deutsche-bahn-data von Piet Brömmel"), usage: String(localized: "Zugstatistik: Verspätungen, Ausfälle und Gleiswechsel der letzten 30 Tage, aus DB Timetables"),
               url: URL(string: "https://github.com/piebro/deutsche-bahn-data")!,
               license: (String(localized: "Lizenz: CC BY 4.0, Deutsche Bahn"), URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!)),
        Source(name: "Deutsche Bahn – Infrastrukturdaten der DB InfraGO", usage: String(localized: "RIL100-Codes der Bahnhöfe"),
               url: URL(string: "https://mobilithek.info/offers/922109165921083392")!,
               license: (String(localized: "Lizenz: CC BY 4.0"), URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!)),
        Source(name: "Deutsche Bahn – Übersicht der Betriebsstellen und deren Abkürzungen", usage: String(localized: "RIL100-Codes der Bahnhöfe im Ausland"),
               url: URL(string: "https://www.dbinfrago.com/resource/blob/12593004/d363d64ef7ecc1792c1518075d8ea769/Download-betriebsstellen-data.xlsx")!),
        Source(name: "Deutsche Bahn – OpenStation der DB InfraGO", usage: String(localized: "Namen der Bahnhöfe, Gleise am selben Bahnsteig und Aufzüge"),
               url: URL(string: "https://mobilithek.info/offers/879076212433727488")!,
               license: (String(localized: "Lizenz: CC0 1.0"), URL(string: "https://creativecommons.org/publicdomain/zero/1.0/deed.de")!)),
        Source(name: "bahn.de", usage: String(localized: "Wagenreihung, Zusatzhalte, Gleise und Zugnamen; Zeichnungen der ICE-Baureihen aus dem Fahrzeuglexikon, © Deutsche Bahn AG"),
               url: URL(string: "https://www.bahn.de")!),
        Source(name: "vagonweb.cz", usage: String(localized: "Geplante Wagenreihungen und Zugtypen, mit Erlaubnis von vagonweb"),
               url: URL(string: "https://www.vagonweb.cz")!),
        Source(name: "bahn.expert", usage: String(localized: "Zugtypen, Zugsuche nach Nummer, Namen der Bahnhöfe; Sitzpläne der ICE aus den Wagenreihungsplänen, © Deutsche Bahn AG"), url: URL(string: "https://bahn.expert")!),
        Source(name: "bahn.jetzt", usage: String(localized: "Zugpositionen auf der Karte"), url: URL(string: "https://bahn.jetzt")!),
        Source(name: "Träwelling", usage: String(localized: "Check-ins"), url: URL(string: "https://traewelling.de")!),
        Source(name: "Open-Meteo", usage: String(localized: "Wetter bei Ankunft und beim Umstieg"),
               url: URL(string: "https://open-meteo.com")!,
               license: (String(localized: "Lizenz: CC BY 4.0"), URL(string: "https://creativecommons.org/licenses/by/4.0/deed.de")!)),
        Source(name: "zug.network", usage: String(localized: "Emojis im Check-in-Text (oder die deiner mit Träwelling verbundenen Mastodon-Instanz)"),
               url: URL(string: "https://zug.network")!),
        Source(name: "OpenStreetMap", usage: String(localized: "Kartendaten des Schienennetzes, Treppen und Aufzüge an den Bahnsteigen, © OpenStreetMap-Mitwirkende"),
               url: URL(string: "https://www.openstreetmap.org/copyright")!,
               license: (String(localized: "Lizenz: ODbL 1.0"), URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!)),
        Source(name: "OpenRailwayMap", usage: String(localized: "Kartenkacheln des Schienennetzes"),
               url: URL(string: "https://www.openrailwaymap.org")!),
        Source(name: "Wikimedia Commons", usage: String(localized: "Logos der Bahnunternehmen, Marken der jeweiligen Unternehmen"),
               url: URL(string: "https://commons.wikimedia.org/wiki/Category:Logos_of_railway_companies")!),
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
