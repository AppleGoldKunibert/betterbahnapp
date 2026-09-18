import Foundation

/// Merges many route lines into segments with a count of how often each stretch was travelled.
///
/// Stretches are matched by actual distance: wherever two lines run within `mergeRadius` of each
/// other they're the same stretch, however their coordinates happen to be sampled. The emitted runs
/// keep the original geometry — the earlier version snapped everything to the centres of a coarse
/// grid, which is what made the lines leave the tracks, take 90° staircase turns, and change colour
/// every time a track happened to cross a cell border.
public struct SegmentHeatmap: Sendable {
    public struct Run: Sendable, Hashable, Codable {
        public var coordinates: [Coordinate]
        public var count: Int
    }

    /// Two tracks closer than this (meters) count as the same stretch — enough to merge parallel
    /// tracks of the same route and the slightly different geometries the data sources return.
    let mergeRadius: Double
    /// Stretches shorter than this (meters) don't get their own colour but inherit the surrounding
    /// count, so a brief encounter with another route can't speckle a long line with other colours.
    let minRunLength: Double

    public init(mergeRadius: Double = 150, minRunLength: Double = 500) {
        self.mergeRadius = mergeRadius
        self.minRunLength = minRunLength
    }

    /// Each line counts once per stretch, even if it loops.
    public func runs(for lines: [[Coordinate]]) -> [Run] {
        // Sample every line finely enough that the matching can't step over a cell. The extra
        // points sit on the original segments, so this changes the shape of nothing.
        let dense = lines.map(densified)
        guard let index = Index(lines: dense, radius: mergeRadius) else { return [] }

        var runs: [Run] = []
        for (line, coordinates) in dense.enumerated() {
            // Which lines run alongside this one at each point — always including itself.
            let cells = coordinates.map(index.cell)
            let neighbours = cells.map(index.lines(in:))
            var counts: [Int?] = (0 ..< max(0, coordinates.count - 1)).map { i in
                // Both ends have to be on the shared stretch, so a line merely brushing past isn't
                // counted. Same cell at both ends means the same set, no intersection needed.
                let shared = cells[i] == cells[i + 1] ? neighbours[i] : neighbours[i].intersection(neighbours[i + 1])
                // Draw a shared stretch once: the lowest-numbered line on it owns it.
                guard shared.min() == line else { return nil }
                return shared.count
            }
            smooth(&counts, along: coordinates)
            runs += emit(coordinates, counts: counts)
        }
        return runs
    }

    // MARK: Spatial index

    /// Which lines pass through each grid cell, widened to the cell's 3×3 neighbourhood.
    ///
    /// The neighbourhood is what makes this robust: with plain cells, two tracks 40 m apart end up
    /// unrelated whenever a cell border happens to run between them, which is what made a single
    /// stretch flip colours along its length. Letting every cell see its neighbours means tracks
    /// within a cell of each other always recognise each other, wherever the borders fall.
    private struct Index {
        struct Cell: Hashable { let x: Int; let y: Int }

        let cellLatitude: Double
        let cellLongitude: Double
        private var neighbourhoods: [Cell: Set<Int>] = [:]

        /// Cells are sized like the merge radius; longitude cells widen towards the poles to stay
        /// roughly square.
        init?(lines: [[Coordinate]], radius: Double) {
            let all = lines.flatMap { $0 }
            guard !all.isEmpty else { return nil }
            let meanLatitude = all.reduce(0.0) { $0 + $1.latitude } / Double(all.count)
            cellLatitude = radius / 111_320
            cellLongitude = radius / (111_320 * max(0.2, cos(meanLatitude * .pi / 180)))

            var occupants: [Cell: Set<Int>] = [:]
            for (line, coordinates) in lines.enumerated() {
                var last: Cell?
                for point in coordinates {
                    let c = cell(point)
                    guard c != last else { continue }
                    occupants[c, default: []].insert(line)
                    last = c
                }
            }
            for c in occupants.keys {
                var union: Set<Int> = []
                for dx in -1 ... 1 {
                    for dy in -1 ... 1 {
                        if let lines = occupants[Cell(x: c.x + dx, y: c.y + dy)] { union.formUnion(lines) }
                    }
                }
                neighbourhoods[c] = union
            }
        }

        func cell(_ c: Coordinate) -> Cell {
            Cell(x: Int((c.longitude / cellLongitude).rounded(.down)),
                 y: Int((c.latitude / cellLatitude).rounded(.down)))
        }

        func lines(in cell: Cell) -> Set<Int> { neighbourhoods[cell] ?? [] }
    }

    // MARK: Geometry

    /// Inserts points so no segment is longer than half the merge radius. Without this, a coarsely
    /// sampled line and a finely sampled one over the same track wouldn't recognise each other.
    private func densified(_ line: [Coordinate]) -> [Coordinate] {
        guard line.count > 1 else { return line }
        var result: [Coordinate] = [line[0]]
        for (a, b) in zip(line, line.dropFirst()) {
            let steps = min(500, max(1, Int((a.distance(to: b) / (mergeRadius / 2)).rounded(.up))))
            for step in 1 ..< steps {
                let t = Double(step) / Double(steps)
                result.append(Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                         longitude: a.longitude + (b.longitude - a.longitude) * t))
            }
            result.append(b)
        }
        return result
    }

    /// Merges runs below `minRunLength` into the stretch before (or after) them. Short gaps are
    /// filled too: drawing a few hundred meters twice is invisible, a hole in the line isn't.
    private func smooth(_ counts: inout [Int?], along line: [Coordinate]) {
        var start = 0
        while start < counts.count {
            var end = start
            while end + 1 < counts.count, counts[end + 1] == counts[start] { end += 1 }
            defer { start = end + 1 }
            let length = (start ... end).reduce(0.0) { $0 + line[$1].distance(to: line[$1 + 1]) }
            guard length < minRunLength else { continue }
            let before: Int? = start > 0 ? counts[start - 1] : nil
            let after: Int? = end + 1 < counts.count ? counts[end + 1] : nil
            if let replacement = before ?? after {
                for i in start ... end { counts[i] = replacement }
            }
        }
    }

    private func emit(_ line: [Coordinate], counts: [Int?]) -> [Run] {
        var runs: [Run] = []
        var current: [Coordinate] = []
        var currentCount = 0
        func flush() {
            // Drop the points densifying added back out: they sit on the line, so they change
            // nothing visually, but they'd multiply what the map has to draw many times over.
            if current.count > 1 {
                runs.append(Run(coordinates: Polyline.simplify(current, tolerance: 8), count: currentCount))
            }
            current = []
        }
        for (index, count) in counts.enumerated() {
            guard let count else { flush(); continue }
            if current.isEmpty || count != currentCount {
                flush()
                // Start on the shared vertex so neighbouring runs meet instead of leaving a seam.
                current = [line[index]]
                currentCount = count
            }
            current.append(line[index + 1])
        }
        flush()
        return runs
    }
}
