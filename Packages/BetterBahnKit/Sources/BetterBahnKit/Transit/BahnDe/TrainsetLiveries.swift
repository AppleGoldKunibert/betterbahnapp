import Foundation

/// Special liveries ("Sonderlackierungen") of DB long-distance trainsets, keyed by Triebzug number.
/// Only designs currently running (checked 2026-10); remove an entry once the design is gone.
enum TrainsetLiveries {
    static let byUnit: [Int: String] = [
        186: "30 Jahre ICE",
        304: "Regenbogen",
        8029: "Blauer Streifen (Europa)",
        8052: "#45 Halfway. Full Speed.",
        8055: "Blauer Streifen (Europa)",
        9046: "Female ICE",
        9223: "75 Jahre Bundespolizei",
        9237: "#StarkeSchiene",
        9457: "Schwarz-Rot-Gold",
        9459: "25 Jahre Miniatur Wunderland",
        9485: "Karriere-ICE",
    ]
}
