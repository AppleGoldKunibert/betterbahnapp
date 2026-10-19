import Foundation

/// The S-Bahn's and U-Bahn's own logos (#350), shown instead of the product symbol on a train's tile:
/// DB's green "S" for German S-Bahns, the blue "U" for U-Bahn and Stadtbahn lines, and the logos of the
/// bigger networks where they have one of their own. Recognised from the line's product and the feed's
/// agency name (`Line.operatorName`, e.g. "Berliner Verkehrsbetriebe", "Hochbahn U-Bahn", "Stadtbahn").
/// The logos are in the app's asset catalog as `Logo-<rawValue>` (from Wikimedia Commons); the test
/// `everyTransitLogoHasAnImage` checks each exists.
public enum TransitLogo: String, CaseIterable, Sendable {
    case sBahn, sBahnAustria
    case uBahn, uBahnBerlin, uBahnHamburg, uBahnMuenchen, uBahnNuernberg, uBahnFrankfurt, uBahnWien
    case stadtbahnStuttgart

    /// U-Bahn and Stadtbahn networks with a logo of their own, as whole words of the normalised agency
    /// name (see `OperatorBrand.normalized`). Every other U-Bahn line (Hannover, Düsseldorf, Rhein-Ruhr, …)
    /// gets the plain "U". Stuttgart's feed names its agency just "Stadtbahn".
    private static let subwayRules: [(TransitLogo, [String])] = [
        (.uBahnBerlin, ["berliner verkehrsbetriebe", "bvg"]),
        (.uBahnHamburg, ["hochbahn"]),
        (.uBahnMuenchen, ["u bahn munchen", "munchner verkehrsgesellschaft", "mvg"]),
        (.uBahnNuernberg, ["u bahn nurnberg", "vag"]),
        (.uBahnFrankfurt, ["verkehrsgesellschaft frankfurt", "vgf"]),
        (.uBahnWien, ["wiener linien"]),
        (.stadtbahnStuttgart, ["stuttgarter strassenbahnen", "stuttgarter straßenbahnen", "ssb"]),
    ]

    /// S-Bahns in Austria (ÖBB's, Salzburger Lokalbahn, GKB) have their own blue "S".
    private static let austrianSuburbanOperators = ["salzburg ag", "salzburger lokalbahn", "gkb", "graz koflacher"]

    /// Railways abroad whose S-trains aren't S-Bahns with DB's "S" (S-Bahn Zürich, S-tog, Esko, …):
    /// they keep the product symbol.
    private static let foreignBrands: Set<OperatorBrand> = [
        .sbb, .sob, .thurbo, .bls, .ns, .cd, .dsb, .pkpic, .polregio, .zssk, .trenitalia, .gysev,
    ]

    public init?(product: Product, operatorName: String?) {
        let name = operatorName.map(OperatorBrand.normalized) ?? ""
        switch product {
        case .suburban:
            let brand = operatorName.flatMap(OperatorBrand.init(operatorName:))
            if brand == .oebb || Self.austrianSuburbanOperators.contains(where: { name.contains(" \($0) ") }) {
                self = .sBahnAustria
            } else if let brand, Self.foreignBrands.contains(brand) {
                return nil
            } else {
                self = .sBahn
            }
        case .subway:
            if name == " stadtbahn " {
                self = .stadtbahnStuttgart
            } else {
                self = Self.subwayRules.first { $0.1.contains { name.contains(" \($0) ") } }?.0 ?? .uBahn
            }
        default:
            return nil
        }
    }

    /// Name of the logo's image set in the app's asset catalog.
    public var assetName: String { "Logo-\(rawValue)" }
}

extension Line {
    /// The S-Bahn's or U-Bahn's logo the app shows instead of the product symbol, if the line has one.
    public var transitLogo: TransitLogo? {
        isNightTrain ? nil : TransitLogo(product: product, operatorName: operatorName)
    }
}
