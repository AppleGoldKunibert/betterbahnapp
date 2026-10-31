import Foundation

/// The trainsets DB Fernverkehr runs, by series and (for the ICE 4) by length: what the collection's
/// "Triebzüge" can be collected from. Tz numbers as DB's coach sequence reports them (BR 407 as 4701…).
///
/// From the German Wikipedia articles on BR 401, 402, 403, 407, 408, 411, 412 and on the IC 2, October
/// 2026: dissolved or retired trainsets are left out (ICE 1 Tz 109, ICE 2 retired since 2024, ICE 3 Tz 326
/// and 351, ICE T Tz 1106/1114–1116/1120–1124, the BR 406 and 415 and the IC 2 KISS), the ICE 3neo is
/// listed with every Tz ordered. A retired trainset someone has ridden still shows up as collected.
enum TrainsetFleet {
    struct Series: Sendable, Hashable {
        /// One of `TravelCollection.series`, e.g. "ICE 4".
        var name: String
        var variants: [Variant]
    }

    struct Variant: Sendable, Hashable {
        /// "7-teilig"; nil where a series has only one.
        var name: String?
        var numbers: [Int]
    }

    static let all: [Series] = [
        Series(name: "ICE 1", variants: [
            Variant(numbers: Array(101...120).filter { $0 != 109 } + Array(152...190)),
        ]),
        Series(name: "ICE 2", variants: [
            Variant(numbers: [201, 202, 204, 206, 208, 210, 211, 213, 220, 221, 222, 223, 224, 225, 226, 228, 229,
                              230, 234, 236, 237, 238, 239, 240, 241, 243]),
        ]),
        Series(name: "ICE 3", variants: [
            Variant(numbers: Array(301...337).filter { $0 != 326 } + Array(352...363)),
        ]),
        Series(name: "ICE 3 Velaro", variants: [Variant(numbers: Array(4701...4717))]),
        Series(name: "ICE 3neo", variants: [Variant(numbers: Array(8001...8090))]),
        Series(name: "ICE 4", variants: [
            Variant(name: String(kit: "7-teilig"), numbers: Array(9201...9237)),
            Variant(name: String(kit: "12-teilig"), numbers: Array(9001...9050)),
            Variant(name: String(kit: "13-teilig"), numbers: Array(9451...9500)),
        ]),
        Series(name: "ICE T", variants: [
            Variant(numbers: Array(1101...1132).filter { ![1106, 1114, 1115, 1116, 1120, 1121, 1122, 1123, 1124].contains($0) }
                + Array(1151...1178) + Array(1180...1184) + Array(1190...1192)),
        ]),
        Series(name: "IC 2 Twindexx", variants: [Variant(numbers: Array(2850...2876) + Array(4877...4919))]),
    ]

    /// The series and variant name of each Tz in `fleet`.
    static func index(_ fleet: [Series]) -> [Int: (series: String, variant: String?)] {
        var result: [Int: (series: String, variant: String?)] = [:]
        for series in fleet {
            for variant in series.variants {
                for number in variant.numbers { result[number] = (series.name, variant.name) }
            }
        }
        return result
    }
}
