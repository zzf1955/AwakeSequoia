import Foundation

/// Logical tree object — separated from GPU InstanceData
struct TreeInstance {
    let x: Float              // world X
    let z: Float              // world Z (forward)
    let rotation: Float       // radians
    let scaleRadial: UInt16   // half-float packed
    let scaleVertical: UInt16 // half-float packed
    let meshType: MeshType

    enum MeshType: Int {
        case forest = 0
    }

    /// Convert to GPU-ready InstanceData for rendering
    func toGPU() -> InstanceData {
        return InstanceData(
            x: x, z: z, rotation: rotation,
            scaleRadial: scaleRadial,
            scaleVertical: scaleVertical
        )
    }
}

/// Fast spatial grid for nearest-tree queries
struct SpatialGrid {
    let cellSize: Float
    private var cells: [Int: [(Float, Float)]] = [:]

    init(cellSize: Float = 2.0) {
        self.cellSize = cellSize
    }

    /// Insert a point into the grid
    mutating func insert(x: Float, z: Float) {
        let key = gridKey(x, z)
        cells[key, default: []].append((x, z))
    }

    /// Insert multiple points
    mutating func insertAll(_ points: [(Float, Float)]) {
        for (x, z) in points {
            insert(x: x, z: z)
        }
    }

    /// Find minimum distance from (x, z) to any point in the grid
    func nearestDist(x: Float, z: Float) -> Float {
        var best: Float = Float.infinity
        let cx = Int(floor(x / cellSize))
        let cz = Int(floor(z / cellSize))
        for dix in -1...1 {
            for diz in -1...1 {
                let key = (cx + dix + 10000) * 100000 + (cz + diz + 10000)
                guard let pts = cells[key] else { continue }
                for (px, pz) in pts {
                    let dx = x - px
                    let dz = z - pz
                    let d = sqrt(dx * dx + dz * dz)
                    if d < best { best = d }
                }
            }
        }
        return best
    }

    /// Find nearest point and return (distance, treeX, treeZ)
    func nearest(x: Float, z: Float) -> (dist: Float, tx: Float, tz: Float) {
        var best: Float = Float.infinity
        var bestTx: Float = 0, bestTz: Float = 0
        let cx = Int(floor(x / cellSize))
        let cz = Int(floor(z / cellSize))
        for dix in -1...1 {
            for diz in -1...1 {
                let key = (cx + dix + 10000) * 100000 + (cz + diz + 10000)
                guard let pts = cells[key] else { continue }
                for (px, pz) in pts {
                    let dx = x - px
                    let dz = z - pz
                    let d = sqrt(dx * dx + dz * dz)
                    if d < best { best = d; bestTx = px; bestTz = pz }
                }
            }
        }
        return (best, bestTx, bestTz)
    }

    /// All points in the grid
    var allPoints: [(Float, Float)] {
        cells.values.flatMap { $0 }
    }

    private func gridKey(_ x: Float, _ z: Float) -> Int {
        let ix = Int(floor(x / cellSize)) + 10000
        let iz = Int(floor(z / cellSize)) + 10000
        return ix * 100000 + iz
    }
}
