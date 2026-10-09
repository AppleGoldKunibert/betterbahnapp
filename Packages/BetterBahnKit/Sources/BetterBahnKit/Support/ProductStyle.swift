#if canImport(SwiftUI)
import SwiftUI

/// Shared visual identity for products, used by the app and the Live Activity.
public extension Product {
    var symbolName: String {
        switch self {
        case .highSpeed: "train.side.front.car"
        case .longDistance, .interregio: "train.side.middle.car"
        case .nightTrain: Self.nightTrainSymbolName
        case .regionalExpress, .regional: "tram.fill"
        case .suburban: "lightrail.fill"
        case .subway: "tram.fill.tunnel"
        case .tram: "cablecar.fill"
        case .bus: "bus.fill"
        case .coach: "bus.doubledecker.fill"
        case .ferry: "ferry.fill"
        case .other: "questionmark.circle.fill"
        }
    }

    /// Night trains get a bed instead, so they're easy to spot (#241).
    func symbolName(nightTrain: Bool) -> String { nightTrain ? Self.nightTrainSymbolName : symbolName }

    static let nightTrainSymbolName = "bed.double.fill"

    var color: Color {
        switch self {
        case .highSpeed, .longDistance, .nightTrain, .interregio: Self.longDistanceColor
        case .regionalExpress, .regional: Color(red: 0.86, green: 0.09, blue: 0.19)
        case .suburban: Color(red: 0.10, green: 0.60, blue: 0.30)
        case .bus, .coach: Color(red: 0.52, green: 0.28, blue: 0.74)
        case .subway: Color(red: 0.12, green: 0.38, blue: 0.80)
        case .tram: Color(red: 0.80, green: 0.45, blue: 0.10)
        case .ferry: Color(red: 0.10, green: 0.55, blue: 0.80)
        case .other: .gray
        }
    }

    /// Black in light mode, a dark gray that still stands out in dark mode.
    private static var longDistanceColor: Color {
        #if canImport(UIKit)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : UIColor(white: 0.10, alpha: 1) })
        #else
        Color(white: 0.12)
        #endif
    }
}

public extension Line {
    /// The product's symbol, or a bed for a night train.
    var symbolName: String { product.symbolName(nightTrain: isNightTrain) }
}
#endif
