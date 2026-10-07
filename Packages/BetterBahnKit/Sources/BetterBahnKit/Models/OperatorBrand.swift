import Foundation

/// Railway undertakings (EVUs) the app has a logo for, recognised from the feed's agency name
/// (`Line.operatorName`, e.g. "DB Regio AG NRW", "OEBB Personenverkehr AG Kundenservice",
/// "S-Bahn Hannover (Transdev)"). The logos are in the app's asset catalog as `Operator-<rawValue>`
/// (from Wikimedia Commons); an operator not listed here keeps the generic icon. To add one, add its case,
/// a rule and its logo (the test `everyBrandHasALogo` checks the asset exists).
public enum OperatorBrand: String, CaseIterable, Sendable {
    case abellio, agilis, alex, arverio, bls, brb, cantus, cd, db, dsb, enno, erfurterbahn, erixx, eurobahn
    case europeansleeper, eurostar, flixtrain, gysev, hlb, laenderbahn, metronom, mrb, nationalexpress
    case nordbahn, nordwestbahn, ns, odeg, oebb, pkpic, polregio, sbahn, sbb, sob, suedthueringenbahn, sweg
    case thurbo, transdev, transregio, trenitalia, vlexx, westfalenbahn, zssk

    /// Whole words of the normalised name (lowercased, without diacritics, punctuation as spaces,
    /// digits stripped from word ends: "vlexx1", "DLB1"). Checked in order, so the specific ones come
    /// first: "alex - Die Länderbahn" is alex, "S-Bahn Hannover (Transdev)" Transdev, "S-Bahn Berlin GmbH"
    /// the S-Bahn's own logo, not DB.
    private static let rules: [(OperatorBrand, [String])] = [
        (.transdev, ["transdev", "s bahn hannover"]),
        (.alex, ["alex"]),
        (.laenderbahn, ["landerbahn"]),
        (.transregio, ["trans regio", "transregio"]),
        (.suedthueringenbahn, ["sud thuringen bahn", "sudthuringenbahn"]),
        (.sob, ["sudostbahn", "sob"]),
        (.sbb, ["sbb", "schweizerische bundesbahnen"]),
        (.oebb, ["oebb", "obb", "osterreichische bundesbahnen"]),
        (.flixtrain, ["flixtrain"]),
        (.nationalexpress, ["national express"]),
        (.nordwestbahn, ["nordwestbahn"]),
        (.nordbahn, ["nordbahn"]),
        (.erixx, ["erixx"]),
        (.metronom, ["metronom"]),
        (.enno, ["enno"]),
        (.odeg, ["odeg", "ostdeutsche eisenbahn"]),
        (.cantus, ["cantus"]),
        (.agilis, ["agilis"]),
        (.arverio, ["arverio"]),
        (.sweg, ["sweg", "sudwestdeutsche verkehrs", "sudwestdeutsche landesverkehrs"]),
        (.europeansleeper, ["european sleeper"]),
        (.eurostar, ["eurostar"]),
        (.thurbo, ["thurbo"]),
        (.eurobahn, ["eurobahn"]),
        (.westfalenbahn, ["westfalenbahn"]),
        (.hlb, ["hlb", "hessische landesbahn"]),
        (.erfurterbahn, ["erfurter bahn"]),
        (.brb, ["brb", "bayerische regiobahn"]),
        (.mrb, ["mrb", "mitteldeutsche regiobahn"]),
        (.abellio, ["abellio"]),
        (.vlexx, ["vlexx"]),
        (.ns, ["ns", "nederlandse spoorwegen"]),
        (.trenitalia, ["trenitalia"]),
        (.bls, ["bls"]),
        (.cd, ["cd", "ceske drahy"]),
        (.pkpic, ["pkp intercity"]),
        (.polregio, ["polregio"]),
        (.gysev, ["gysev", "raaberbahn"]),
        (.zssk, ["zssk", "zeleznicna spolocnost slovensko"]),
        (.dsb, ["dsb", "danske statsbaner"]),
        (.sbahn, ["s bahn berlin"]),
        (.db, ["db", "deutsche bahn", "s bahn hamburg"]),
    ]

    public init?(operatorName: String) {
        let words = operatorName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { String($0.reversed().drop(while: \.isNumber).reversed()) }
            .filter { !$0.isEmpty }
        let name = " " + words.joined(separator: " ") + " "
        guard let brand = Self.rules.first(where: { $0.1.contains { name.contains(" \($0) ") } })?.0 else { return nil }
        self = brand
    }

    /// Name of the logo's image set in the app's asset catalog.
    public var assetName: String { "Operator-\(rawValue)" }

    /// Whether the logo needs a light plate in dark mode: black or dark blue lettering is unreadable on
    /// the dark background. Logos that are bright enough sit on the background directly, as in light mode.
    public var needsPlateInDarkMode: Bool {
        switch self {
        case .db, .dsb, .erfurterbahn, .europeansleeper, .eurostar, .flixtrain, .gysev, .nationalexpress, .oebb,
             .polregio, .sbahn, .sob, .thurbo, .transdev, .trenitalia, .westfalenbahn, .zssk:
            false
        case .abellio, .agilis, .alex, .arverio, .bls, .brb, .cantus, .cd, .enno, .erixx, .eurobahn, .hlb,
             .laenderbahn, .metronom, .mrb, .nordbahn, .nordwestbahn, .ns, .odeg, .pkpic, .sbb,
             .suedthueringenbahn, .sweg, .transregio, .vlexx:
            true
        }
    }

    /// The name to show for operators whose feed name is long-winded: "ODEG" for
    /// "ODEG Ostdeutsche Eisenbahn GmbH". `nil` keeps the feed's name.
    public var shortName: String? {
        switch self {
        case .odeg: "ODEG"
        default: nil
        }
    }

    /// Railways from abroad. Their S-Bahn trains (Zürich, Salzburg, …) don't carry Germany's S-Bahn logo.
    public var isForeign: Bool {
        switch self {
        case .bls, .cd, .dsb, .eurostar, .gysev, .ns, .oebb, .pkpic, .polregio, .sbb, .sob, .thurbo, .trenitalia, .zssk:
            true
        default:
            false
        }
    }

    /// The logo for a train run by `operatorName`: every S-Bahn train shows the S-Bahn's "S", whoever runs
    /// it (DB Regio in München, Transdev in Hannover, NordWestBahn in Bremen), unless a railway from abroad
    /// does; other trains their operator's logo.
    public static func brand(operatorName: String?, product: Product?) -> OperatorBrand? {
        let brand = operatorName.flatMap(OperatorBrand.init(operatorName:))
        if product == .suburban, brand?.isForeign != true { return .sbahn }
        return brand
    }

    /// `operatorName` as the app shows it, shortened where the brand has a short name.
    public static func displayName(for operatorName: String) -> String {
        OperatorBrand(operatorName: operatorName)?.shortName ?? operatorName
    }
}

extension Line {
    /// The logo the app shows next to `operatorName`, if there is one: the S-Bahn's for S-Bahn trains
    /// (`OperatorBrand.brand(operatorName:product:)`), else the operator's.
    public var operatorBrand: OperatorBrand? { OperatorBrand.brand(operatorName: operatorName, product: product) }
}
