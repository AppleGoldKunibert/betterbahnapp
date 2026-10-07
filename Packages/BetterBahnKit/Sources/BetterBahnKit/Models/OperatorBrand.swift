import Foundation

/// Railway undertakings (EVUs) the app has a logo for, recognised from the feed's agency name
/// (`Line.operatorName`, e.g. "DB Regio AG NRW", "OEBB Personenverkehr AG Kundenservice",
/// "S-Bahn Hannover (Transdev)"). The logos are in the app's asset catalog as `Operator-<rawValue>`
/// (from Wikimedia Commons); an operator not listed here keeps the generic icon. To add one, add its case,
/// a rule and its logo (the test `everyBrandHasALogo` checks the asset exists).
public enum OperatorBrand: String, CaseIterable, Sendable {
    case abellio, agilis, alex, arverio, bls, brb, cantus, cd, db, dbregio, dsb, enno, erfurterbahn, erixx, eurobahn
    case europeansleeper, eurostar, flixtrain, gysev, hlb, laenderbahn, metronom, mrb, nationalexpress
    case nordbahn, nordwestbahn, ns, odeg, oebb, pkpic, polregio, sbahn, sbb, sob, suedthueringenbahn, sweg
    case thurbo, transdev, transregio, trenitalia, vlexx, westfalenbahn, zssk

    /// Whole words of the normalised name (lowercased, without diacritics, punctuation as spaces,
    /// digits stripped from word ends: "vlexx1", "DLB1"). Checked in order, so the specific ones come
    /// first: "alex - Die Länderbahn" is alex, "S-Bahn Hannover (Transdev)" Transdev, not DB. DB's S-Bahns
    /// with a name of their own ("S-Bahn Berlin GmbH", "DB Regio AG S-Bahn München") get the S-Bahn's "S";
    /// other DB Regio trains ("DB Regio AG NRW") DB Regio's logo, everything else of DB's DB's.
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
        (.dsb, ["dsb", "danske statsbaner", "danische staatsbahnen"]),
        (.sbahn, ["s bahn"]),
        (.dbregio, ["db regio"]),
        (.db, ["db", "deutsche bahn"]),
    ]

    public init?(operatorName: String) {
        let name = Self.normalized(operatorName)
        guard let brand = Self.rules.first(where: { $0.1.contains { name.contains(" \($0) ") } })?.0 else { return nil }
        self = brand
    }

    /// The name's words as the rules match them, with a space before and after.
    private static func normalized(_ operatorName: String) -> String {
        let words = operatorName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { String($0.reversed().drop(while: \.isNumber).reversed()) }
            .filter { !$0.isEmpty }
        return " " + words.joined(separator: " ") + " "
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
        case .abellio, .agilis, .alex, .arverio, .bls, .brb, .cantus, .cd, .dbregio, .enno, .erixx, .eurobahn, .hlb,
             .laenderbahn, .metronom, .mrb, .nordbahn, .nordwestbahn, .ns, .odeg, .pkpic, .sbb,
             .suedthueringenbahn, .sweg, .transregio, .vlexx:
            true
        }
    }

    /// `operatorName` as the app shows it, where the feed's name is long-winded or names no company:
    /// "ODEG" for "ODEG Ostdeutsche Eisenbahn GmbH", "Transdev" for "S-Bahn Hannover (Transdev)" (the S-Bahn
    /// Hannover is Transdev's network, not a company of its own). Other names stay as they are.
    public static func displayName(for operatorName: String) -> String {
        switch OperatorBrand(operatorName: operatorName) {
        case .odeg: "ODEG"
        case .transdev where normalized(operatorName).contains(" s bahn hannover "): "Transdev"
        default: operatorName
        }
    }
}

extension Line {
    /// The operator whose logo the app shows next to `operatorName`, if it has one.
    public var operatorBrand: OperatorBrand? { operatorName.flatMap(OperatorBrand.init(operatorName:)) }
}
