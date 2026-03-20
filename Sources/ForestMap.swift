import Foundation

/// Block coordinate in the grid
struct BlockCoord: Hashable {
    let bx: Int
    let bz: Int
}

/// A fixed-size region containing trees + spatial index
struct Block {
    let coord: BlockCoord
    var trees: [TreeInstance]
    var spatialGrid: SpatialGrid
    let worldZMin: Float
    let worldZMax: Float
    let worldXMin: Float
    let worldXMax: Float
}

/// World map: manages Block grid, tree generation/recycling, spatial queries
class ForestMap {
    var blockSize: Float = 16.0
    var blockWidth: Float = 13.0
    var xMin: Float { -blockWidth / 2.0 }
    var xMax: Float { blockWidth / 2.0 }
    let baseSeed: UInt64

    /// Forest tree density: trees per unit area (default 1.56 ≈ 1/0.8², matching original spacing=0.8)
    var forestDensity: Float = 1.5625

    /// Minimum clearance (used for tree-tree overlap removal)
    var minClearance: Float = 0.3

    /// Clear zone at starting point: (halfWidth, depth) — removes trees in [-hw, hw] x [0, depth]
    var startClearZone: (halfWidth: Float, depth: Float) = (1.0, 2.0)

    private(set) var blocks: [BlockCoord: Block] = [:]

    /// Global spatial grid across all loaded blocks (rebuilt on load/unload)
    private(set) var globalGrid: SpatialGrid

    init(seed: UInt64 = 42) {
        self.baseSeed = seed
        self.globalGrid = SpatialGrid(cellSize: 4.0)
    }

    // MARK: - Bridson's Poisson Disk Sampling

    /// Generate well-spaced points using Bridson's algorithm.
    /// All points are guaranteed to be at least `minDist` apart.
    private func bridsonPoissonDisk(
        xMin: Float, xMax: Float, zMin: Float, zMax: Float,
        minDist: Float, rng: inout SeededRNG, k: Int = 30
    ) -> [(Float, Float)] {
        let w = xMax - xMin, h = zMax - zMin
        let cellSize = minDist / sqrt(2.0)
        let cols = max(1, Int(ceil(w / cellSize)))
        let rows = max(1, Int(ceil(h / cellSize)))

        // Background grid: -1 = empty, otherwise index into points
        var grid = [Int](repeating: -1, count: cols * rows)
        var points: [(Float, Float)] = []
        var active: [Int] = []

        func gridIndex(x: Float, z: Float) -> (Int, Int) {
            let c = min(max(Int((x - xMin) / cellSize), 0), cols - 1)
            let r = min(max(Int((z - zMin) / cellSize), 0), rows - 1)
            return (c, r)
        }

        // Start with a random initial point
        let p0x = xMin + rng.nextFloat() * w
        let p0z = zMin + rng.nextFloat() * h
        points.append((p0x, p0z))
        active.append(0)
        let (c0, r0) = gridIndex(x: p0x, z: p0z)
        grid[r0 * cols + c0] = 0

        while !active.isEmpty {
            // Pick a random active point
            let ai = Int(rng.nextFloat() * Float(active.count)) % active.count
            let pi = active[ai]
            let (px, pz) = points[pi]
            var found = false

            for _ in 0..<k {
                let angle = rng.nextFloat() * 2.0 * Float.pi
                let dist = minDist + rng.nextFloat() * minDist
                let cx = px + cos(angle) * dist
                let cz = pz + sin(angle) * dist

                // Check bounds
                guard cx >= xMin && cx < xMax && cz >= zMin && cz < zMax else { continue }

                let (cc, cr) = gridIndex(x: cx, z: cz)

                // Check neighbors in a 5x5 grid around candidate
                var tooClose = false
                for dr in -2...2 {
                    for dc in -2...2 {
                        let nr = cr + dr, nc = cc + dc
                        guard nr >= 0 && nr < rows && nc >= 0 && nc < cols else { continue }
                        let ni = grid[nr * cols + nc]
                        if ni >= 0 {
                            let (nx, nz) = points[ni]
                            let dx = cx - nx, dz = cz - nz
                            if dx * dx + dz * dz < minDist * minDist {
                                tooClose = true
                                break
                            }
                        }
                    }
                    if tooClose { break }
                }

                if !tooClose {
                    let newIdx = points.count
                    points.append((cx, cz))
                    active.append(newIdx)
                    grid[cr * cols + cc] = newIdx
                    found = true
                    break
                }
            }

            if !found {
                active.swapAt(ai, active.count - 1)
                active.removeLast()
            }
        }

        return points
    }

    /// Generate and load a block at the given coordinate
    @discardableResult
    func loadBlock(_ coord: BlockCoord) -> Block {
        if let existing = blocks[coord] { return existing }

        // Deterministic RNG based on seed + block coordinate
        let blockSeed = baseSeed &+ UInt64(bitPattern: Int64(coord.bx) &* 73856093) &+ UInt64(bitPattern: Int64(coord.bz) &* 19349663)
        var rng = SeededRNG(seed: blockSeed)

        let worldZMin = Float(coord.bz) * blockSize
        let worldZMax = worldZMin + blockSize
        let worldXMin = xMin
        let worldXMax = xMax

        let minDist: Float = 1.0 / sqrt(forestDensity)
        var trees: [TreeInstance] = []
        var gridPoints: [(Float, Float)] = []

        // Forest trees: Poisson disk sampling (guaranteed min spacing)
        let diskPoints = bridsonPoissonDisk(
            xMin: worldXMin, xMax: worldXMax,
            zMin: worldZMin, zMax: worldZMax,
            minDist: minDist, rng: &rng
        )
        for (px, pz) in diskPoints {
            let scaleR = 0.7 + rng.nextFloat() * 0.6
            let scaleV = 0.7 + rng.nextFloat() * 0.6
            let rotation = rng.nextFloat() * Float.pi * 2.0
            trees.append(TreeInstance(
                x: px, z: pz, rotation: rotation,
                scaleRadial: floatToHalf(scaleR),
                scaleVertical: floatToHalf(scaleV),
                meshType: .forest
            ))
            gridPoints.append((px, pz))
        }

        // Clear trees near starting point (block 0 and block -1)
        if coord == BlockCoord(bx: 0, bz: 0) || coord == BlockCoord(bx: 0, bz: -1) {
            let hw = startClearZone.halfWidth
            let dp = startClearZone.depth
            let keep = trees.enumerated().filter { (_, t) in
                !(t.x >= -hw && t.x <= hw && t.z >= -dp && t.z <= dp)
            }.map { $0.offset }
            trees = keep.map { trees[$0] }
            gridPoints = keep.map { gridPoints[$0] }
        }

        // Build spatial grid for this block
        var grid = SpatialGrid(cellSize: 2.0)
        grid.insertAll(gridPoints)

        let block = Block(
            coord: coord, trees: trees, spatialGrid: grid,
            worldZMin: worldZMin, worldZMax: worldZMax,
            worldXMin: worldXMin, worldXMax: worldXMax
        )
        blocks[coord] = block

        // Add to global grid
        for (px, pz) in gridPoints {
            globalGrid.insert(x: px, z: pz)
        }

        return block
    }

    /// Unload a block (remove from memory)
    func unloadBlock(_ coord: BlockCoord) {
        blocks.removeValue(forKey: coord)
        rebuildGlobalGrid()
    }

    /// Remove trees that overlap with the planned path
    func removeTreesNearPath(blockCoord: BlockCoord, pathPoints: [(Float, Float)], clearance: Float) {
        guard var block = blocks[blockCoord] else { return }
        let cl2 = clearance * clearance
        let before = block.trees.count
        block.trees.removeAll { tree in
            for pt in pathPoints {
                let dx = tree.x - pt.0, dz = tree.z - pt.1
                if dx * dx + dz * dz < cl2 { return true }
            }
            return false
        }
        let removed = before - block.trees.count
        if removed > 0 {
            var grid = SpatialGrid(cellSize: 2.0)
            grid.insertAll(block.trees.map { ($0.x, $0.z) })
            block.spatialGrid = grid
            blocks[blockCoord] = block
            rebuildGlobalGrid()
        }
    }

    /// Rebuild global grid from all loaded blocks
    private func rebuildGlobalGrid() {
        globalGrid = SpatialGrid(cellSize: 4.0)
        for block in blocks.values {
            for tree in block.trees {
                globalGrid.insert(x: tree.x, z: tree.z)
            }
        }
    }

    /// Nearest tree distance across all loaded blocks
    func nearestTreeDist(x: Float, z: Float) -> Float {
        return globalGrid.nearestDist(x: x, z: z)
    }

    /// Nearest tree with position
    func nearestTree(x: Float, z: Float) -> (dist: Float, tx: Float, tz: Float) {
        return globalGrid.nearest(x: x, z: z)
    }

    /// Collect all TreeInstances in a Z range
    func instancesInRange(zMin: Float, zMax: Float) -> [TreeInstance] {
        var result: [TreeInstance] = []
        for block in blocks.values {
            if block.worldZMax < zMin - 2.0 || block.worldZMin > zMax + 2.0 { continue }
            for tree in block.trees {
                if tree.z >= zMin - 2.0 && tree.z <= zMax + 2.0 {
                    result.append(tree)
                }
            }
        }
        return result
    }

    /// Collect all tree centers in a Z range (for path planning)
    func treeCenters(zMin: Float, zMax: Float) -> [(Float, Float)] {
        var centers: [(Float, Float)] = []
        for block in blocks.values {
            if block.worldZMax < zMin - 2.0 || block.worldZMin > zMax + 2.0 { continue }
            for tree in block.trees {
                if tree.z >= zMin - 2.0 && tree.z <= zMax + 2.0 {
                    centers.append((tree.x, tree.z))
                }
            }
        }
        return centers
    }

    /// All tree centers across all loaded blocks
    func allTreeCenters() -> [(Float, Float)] {
        var centers: [(Float, Float)] = []
        for block in blocks.values {
            for tree in block.trees {
                centers.append((tree.x, tree.z))
            }
        }
        return centers
    }

    /// Block coordinate for a given world Z position
    func blockCoordForZ(_ z: Float) -> Int {
        return Int(floor(z / blockSize))
    }

    /// Total Z range of loaded blocks
    var loadedZRange: (min: Float, max: Float) {
        guard !blocks.isEmpty else { return (0, 0) }
        let minZ = blocks.values.map { $0.worldZMin }.min()!
        let maxZ = blocks.values.map { $0.worldZMax }.max()!
        return (minZ, maxZ)
    }
}
