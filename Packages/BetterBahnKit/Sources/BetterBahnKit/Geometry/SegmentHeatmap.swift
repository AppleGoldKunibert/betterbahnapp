import Foundation

/// Merges many route lines into segments with a count of how often each stretch was travelled.
public struct SegmentHeatmap: Sendable {
    public struct Run: Sendable, Hashable, Codable {
        public var coordinates: [Coordinate]
        public var count: Int
    }

    /// Grid size in degrees used to treat parallel tracks as the same stretch (~150 m).
    let gridSize: Double

    public init(gridSize: Double = 0.0015) {
        self.gridSize = gridSize
    }

    struct Cell: Hashable { let x: Int; let y: Int }
    struct Edge: Hashable {
        let a: Cell, b: Cell
        init(_ p: Cell, _ q: Cell) {
            if (p.x, p.y) < (q.x, q.y) { a = p; b = q } else { a = q; b = p }
        }
    }

    func cell(_ c: Coordinate) -> Cell {
        Cell(x: Int((c.longitude / gridSize).rounded()), y: Int((c.latitude / gridSize).rounded()))
    }

    func center(_ cell: Cell) -> Coordinate {
        Coordinate(latitude: Double(cell.y) * gridSize, longitude: Double(cell.x) * gridSize)
    }

    /// Each line counts once per stretch, even if it loops.
    public func runs(for lines: [[Coordinate]]) -> [Run] {
        // 1. Snap every line to the grid.
        let snapped: [[Cell]] = lines.map { line in
            var cells: [Cell] = []
            for c in line {
                let next = cell(c)
                if cells.last != next { cells.append(next) }
            }
            return cells
        }
        // 2. Count edges.
        var counts: [Edge: Int] = [:]
        for cells in snapped {
            let edges = Set(zip(cells, cells.dropFirst()).map { Edge($0.0, $0.1) })
            for edge in edges { counts[edge, default: 0] += 1 }
        }
        // 3. Walk lines again and emit runs of equal count, each edge only once.
        var emitted = Set<Edge>()
        var runs: [Run] = []
        for cells in snapped {
            var current: [Coordinate] = []
            var currentCount = 0
            func flush() {
                if current.count > 1 { runs.append(Run(coordinates: current, count: currentCount)) }
                current = []
            }
            for (p, q) in zip(cells, cells.dropFirst()) {
                let edge = Edge(p, q)
                guard !emitted.contains(edge), let count = counts[edge] else { flush(); continue }
                emitted.insert(edge)
                if count != currentCount || current.isEmpty {
                    flush()
                    current = [center(p)]
                    currentCount = count
                }
                current.append(center(q))
            }
            flush()
        }
        return runs
    }
}
