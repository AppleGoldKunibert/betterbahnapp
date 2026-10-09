import BetterBahnKit
import SwiftUI

/// UI-side row for an in-progress via point: it needs a stable identity before a station has
/// even been picked, which `ViaWaypoint` (identified by station id) can't provide.
struct ViaRow: Identifiable {
    let id = UUID()
    var station: Station?
    var minStayMinutes = 0

    init(station: Station? = nil, minStayMinutes: Int = 0) {
        self.station = station
        self.minStayMinutes = minStayMinutes
    }

    init(_ waypoint: ViaWaypoint) {
        station = waypoint.station
        minStayMinutes = waypoint.minStayMinutes
    }

    /// The waypoint this row stands for, once a station has been picked.
    func waypoint(products: Set<Product>? = nil) -> ViaWaypoint? {
        station.map { ViaWaypoint(station: $0, minStayMinutes: minStayMinutes, products: products) }
    }
}

extension Array where Element == ViaRow {
    /// The rows that are ready to be searched with.
    func waypoints(products: (ViaRow) -> Set<Product>? = { _ in nil }) -> [ViaWaypoint] {
        compactMap { $0.waypoint(products: products($0)) }
    }
}

/// One intermediate stop in a route card: a station field plus its minimum-stay control.
struct ViaRowView<Focus: Hashable>: View {
    @Binding var row: ViaRow
    let focus: FocusState<Focus?>.Binding
    let focusValue: Focus
    let onRemove: () -> Void

    @State private var showStayPopover = false

    var body: some View {
        VStack(spacing: 0) {
            StationInput(label: "Zwischenhalt", placeholder: "Über welchen Ort?", systemImage: "smallcircle.filled.circle",
                         iconColor: .secondary, station: $row.station, focus: focus, focusValue: focusValue)

            HStack(spacing: 10) {
                Button {
                    showStayPopover = true
                } label: {
                    Label(row.minStayMinutes > 0 ? "Mind. \(row.minStayMinutes) Min." : "Mindestaufenthalt",
                          systemImage: "clock.badge.checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(row.minStayMinutes > 0 ? Color.brand : Color.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showStayPopover) {
                    MinimumStayPopover(minutes: $row.minStayMinutes, stationName: row.station?.displayName,
                                       isPresented: $showStayPopover)
                }

                Spacer()

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Zwischenhalt entfernen")
            }
            .padding(.leading, 54)
            .padding(.trailing, 16)
            .padding(.bottom, 12)
        }
    }
}

/// Stepper for how long to stay at a stop before travelling on.
struct MinimumStayPopover: View {
    @Binding var minutes: Int
    var stationName: String?
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Mindestaufenthalt in \(stationName ?? "diesem Ort")")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Stepper("\(minutes) Minuten", value: $minutes, in: 0...120, step: 5)
                .fixedSize()
            Button("Fertig") { isPresented = false }
                .buttonStyle(.glassProminent)
                .tint(.brand)
        }
        .padding()
        .frame(minWidth: 260)
        .presentationCompactAdaptation(.popover)
    }
}

/// Quick presets and toggle chips for choosing which vehicle types may be used.
struct ProductChips: View {
    @Binding var products: Set<Product>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Nur Züge") { products = Set(Product.allCases.filter(\.isTrain)) }
                Button("Nur Fernverkehr") { products = Product.longDistanceProducts }
                Button("Alle") { products = Set(Product.allCases) }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Product.allCases, id: \.self) { product in
                    let isOn = products.contains(product)
                    Button {
                        if isOn { products.remove(product) } else { products.insert(product) }
                    } label: {
                        Label(product.displayName, systemImage: product.symbolName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .background(isOn ? product.color : Color.secondary.opacity(0.15), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Segmented picker for the transfer limit of a search.
struct MaxTransfersPicker: View {
    @Binding var maxTransfers: Int?

    var body: some View {
        Picker("Max. Umstiege", selection: $maxTransfers) {
            Text("Beliebig").tag(Int?.none)
            Text("Direkt").tag(Int?.some(0))
            Text("≤ 1").tag(Int?.some(1))
            Text("≤ 2").tag(Int?.some(2))
        }
        .pickerStyle(.segmented)
    }
}

/// Icon + title + subtitle row used by the search option cards.
struct OptionLabel: View {
    let title: String
    let subtitle: String
    let icon: String
    var color: Color = .brand

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: icon, color: color, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Human-readable summary of a vehicle-type selection.
func productSummary(_ products: Set<Product>) -> String {
    if products.count == Product.allCases.count { return "Alle" }
    let names = Product.allCases.filter(products.contains).map(\.displayName)
    return names.isEmpty ? "Keine ausgewählt" : names.joined(separator: ", ")
}
