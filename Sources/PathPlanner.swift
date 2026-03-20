import Foundation

// MARK: - Data Structures for Voronoi + Dijkstra + B-spline

struct DelaunayTriangle {
    let a, b, c: Int
    var circumX, circumY, circumR2: Float
}

struct VoronoiVertex {
    let x, y: Float
    let clearance: Float
}

struct VoronoiEdge {
    let from, to: Int
    let length, minClearance, weight: Float
}

// MARK: - Priority Queue for Dijkstra

struct PriorityQueue {
    private var heap: [(Float, Int)] = []

    var isEmpty: Bool { heap.isEmpty }

    mutating func insert(_ priority: Float, _ value: Int) {
        heap.append((priority, value))
        siftUp(heap.count - 1)
    }

    mutating func extractMin() -> (Float, Int)? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let min = heap[0]
        heap[0] = heap.removeLast()
        siftDown(0)
        return min
    }

    private mutating func siftUp(_ i: Int) {
        var i = i
        while i > 0 {
            let parent = (i - 1) / 2
            if heap[i].0 < heap[parent].0 {
                heap.swapAt(i, parent)
                i = parent
            } else { break }
        }
    }

    private mutating func siftDown(_ i: Int) {
        var i = i
        let n = heap.count
        while true {
            var smallest = i
            let l = 2 * i + 1, r = 2 * i + 2
            if l < n && heap[l].0 < heap[smallest].0 { smallest = l }
            if r < n && heap[r].0 < heap[smallest].0 { smallest = r }
            if smallest == i { break }
            heap.swapAt(i, smallest)
            i = smallest
        }
    }
}

// MARK: - Path Segment

struct PathSegment {
    let points: [(Float, Float)]   // dense-sampled path points
    let yaw: [Float]               // corresponding heading
    let length: Float              // world length of this segment
}

// MARK: - PathPlanner

struct PathPlanner {
    var minClearance: Float = 0.3
    var corridorAlpha: Float = 1.0
    var pathXMin: Float = -4.0
    var pathXMax: Float = 4.0

    /// Accumulated path segments
    private(set) var segments: [PathSegment] = []

    /// Cumulative length of all segments
    private(set) var totalLength: Float = 0

    /// Dense path points (concatenated from all segments)
    private(set) var pathPoints: [(Float, Float)] = []
    private(set) var pathYaw: [Float] = []

    /// Cumulative arc-length at each path point
    private var arcLength: [Float] = []

    /// Set a fixed quarter-circle path for debugging
    /// Center at (0, 0), radius R, from angle -90° (pointing +Z) sweeping to 0° (pointing +X)
    /// Path goes from (0, R) along the arc to (R, 0) — or similar geometry
    mutating func setQuarterCirclePath(radius: Float = 10.0, numPoints: Int = 500) {
        pathPoints = []
        pathYaw = []
        pathPoints.reserveCapacity(numPoints)
        pathYaw.reserveCapacity(numPoints)

        // Quarter circle: center at (radius, 0), from angle π (x=0, z=0) to π/2 (x=radius, z=radius)
        // This gives a path from (0, 0) curving right to (radius, radius)
        let cx: Float = radius
        let cz: Float = 0.0
        for i in 0..<numPoints {
            let t = Float(i) / Float(numPoints - 1)
            let angle = Float.pi - t * (Float.pi / 2.0)  // π → π/2
            let x = cx + radius * cos(angle)
            let z = cz + radius * sin(angle)
            pathPoints.append((x, z))

            // yaw computed from consecutive points below
        }

        // Recompute yaw from path direction
        pathYaw = []
        for i in 0..<pathPoints.count {
            if i < pathPoints.count - 1 {
                let dx = pathPoints[i + 1].0 - pathPoints[i].0
                let dz = pathPoints[i + 1].1 - pathPoints[i].1
                pathYaw.append(atan2(dx, dz))
            } else {
                pathYaw.append(pathYaw.last ?? 0)
            }
        }

        buildArcLength()
        print("  Quarter-circle path: \(numPoints) points, radius=\(radius), length=\(String(format: "%.1f", totalLength))")
    }

    /// Generate full path for a given Z range using tree centers from ForestMap
    mutating func generateFullPath(map: ForestMap, zStart: Float, zEnd: Float) {
        let treeCenters = map.treeCenters(zMin: zStart - 3.0, zMax: zEnd + 3.0)

        // Build spatial grid for tree lookups
        var treeGrid = SpatialGrid(cellSize: 4.0)
        treeGrid.insertAll(treeCenters)

        // Step 1: Boundary virtual points
        var points: [(Float, Float)] = treeCenters
        let margin: Float = 3.0
        let spacing: Float = 2.0
        let xMin = pathXMin - margin
        let xMax = pathXMax + margin
        let zMin = zStart - margin
        let zMax = zEnd + margin

        var bx = xMin
        while bx <= xMax { points.append((bx, zMin)); bx += spacing }
        bx = xMin
        while bx <= xMax { points.append((bx, zMax)); bx += spacing }
        var bz = zMin + spacing
        while bz < zMax { points.append((xMin, bz)); bz += spacing }
        bz = zMin + spacing
        while bz < zMax { points.append((xMax, bz)); bz += spacing }

        print("  Voronoi: \(treeCenters.count) trees + \(points.count - treeCenters.count) boundary = \(points.count) points")

        // Step 2: Bowyer-Watson Delaunay triangulation
        let triangles = bowyerWatson(points: points)
        print("  Delaunay: \(triangles.count) triangles")

        // Step 3: Extract Voronoi graph
        var voronoiVertices: [VoronoiVertex] = []
        var voronoiAdj: [[Int]] = []
        var voronoiEdges: [VoronoiEdge] = []
        var triToVoronoi: [Int: Int] = [:]

        for (ti, tri) in triangles.enumerated() {
            let cx = tri.circumX
            let cy = tri.circumY
            let clearance = treeGrid.nearestDist(x: cx, z: cy)

            if cx < pathXMin || cx > pathXMax { continue }
            if cy < zStart || cy > zEnd { continue }
            let filterClearance = minClearance * 1.2
            if clearance < filterClearance { continue }

            let vi = voronoiVertices.count
            voronoiVertices.append(VoronoiVertex(x: cx, y: cy, clearance: clearance))
            voronoiAdj.append([])
            triToVoronoi[ti] = vi
        }

        // Build Voronoi edges from shared Delaunay edges
        var edgeToTriangles: [Int64: [Int]] = [:]
        for (ti, tri) in triangles.enumerated() {
            guard triToVoronoi[ti] != nil else { continue }
            let edges = [edgeKey(tri.a, tri.b), edgeKey(tri.b, tri.c), edgeKey(tri.a, tri.c)]
            for ek in edges {
                edgeToTriangles[ek, default: []].append(ti)
            }
        }

        for (_, tris) in edgeToTriangles {
            if tris.count != 2 { continue }
            guard let vi0 = triToVoronoi[tris[0]],
                  let vi1 = triToVoronoi[tris[1]] else { continue }

            let v0 = voronoiVertices[vi0]
            let v1 = voronoiVertices[vi1]

            let dx = v1.x - v0.x
            let dy = v1.y - v0.y
            let edgeLen = sqrt(dx * dx + dy * dy)
            if edgeLen < 1e-6 { continue }

            // Sample edge for min clearance
            var edgeMinClear: Float = Float.infinity
            for s in 0...5 {
                let t = Float(s) / 5.0
                let sx = v0.x + t * dx
                let sy = v0.y + t * dy
                let c = treeGrid.nearestDist(x: sx, z: sy)
                if c < edgeMinClear { edgeMinClear = c }
            }

            if edgeMinClear < minClearance * 1.2 { continue }

            let weight = edgeLen / pow(max(edgeMinClear, 0.01), corridorAlpha)

            let ei = voronoiEdges.count
            voronoiEdges.append(VoronoiEdge(from: vi0, to: vi1, length: edgeLen,
                                             minClearance: edgeMinClear, weight: weight))
            voronoiAdj[vi0].append(ei)

            let ei2 = voronoiEdges.count
            voronoiEdges.append(VoronoiEdge(from: vi1, to: vi0, length: edgeLen,
                                             minClearance: edgeMinClear, weight: weight))
            voronoiAdj[vi1].append(ei2)
        }

        print("  Voronoi graph: \(voronoiVertices.count) vertices, \(voronoiEdges.count / 2) edges")

        // Step 4: Dijkstra from virtual start to virtual end
        let startX: Float = 0.0, startZ: Float = zStart
        let endX: Float = 0.0, endZ: Float = zEnd

        let startVi = voronoiVertices.count
        voronoiVertices.append(VoronoiVertex(x: startX, y: startZ, clearance: Float.infinity))
        voronoiAdj.append([])

        let endVi = voronoiVertices.count
        voronoiVertices.append(VoronoiVertex(x: endX, y: endZ, clearance: Float.infinity))
        voronoiAdj.append([])

        connectVirtualVertex(startVi, x: startX, z: startZ,
                            vertices: &voronoiVertices, adj: &voronoiAdj,
                            edges: &voronoiEdges, k: 10)
        connectVirtualVertex(endVi, x: endX, z: endZ,
                            vertices: &voronoiVertices, adj: &voronoiAdj,
                            edges: &voronoiEdges, k: 10)

        // Run Dijkstra
        let n = voronoiVertices.count
        var dist = [Float](repeating: Float.infinity, count: n)
        var prev = [Int](repeating: -1, count: n)
        dist[startVi] = 0

        var pq = PriorityQueue()
        pq.insert(0, startVi)

        while let (d, u) = pq.extractMin() {
            if d > dist[u] { continue }
            if u == endVi { break }
            for ei in voronoiAdj[u] {
                let edge = voronoiEdges[ei]
                let nd = d + edge.weight
                if nd < dist[edge.to] {
                    dist[edge.to] = nd
                    prev[edge.to] = u
                    pq.insert(nd, edge.to)
                }
            }
        }

        // Extract path
        var pathVertices: [(Float, Float)] = []
        if dist[endVi] < Float.infinity {
            var cur = endVi
            while cur != -1 {
                pathVertices.append((voronoiVertices[cur].x, voronoiVertices[cur].y))
                cur = prev[cur]
            }
            pathVertices.reverse()
        }

        print("  Dijkstra path: \(pathVertices.count) vertices, cost=\(String(format: "%.4f", dist[endVi]))")

        guard pathVertices.count >= 2 else {
            print("  WARNING: Dijkstra found no path! Falling back to straight line.")
            pathPoints = [(0, zStart), (0, zEnd)]
            pathYaw = [0, 0]
            buildArcLength()
            return
        }

        // Step 5: Cubic uniform B-spline
        evaluateBSpline(controlPoints: pathVertices)

        // Step 6: Build arc-length table
        buildArcLength()

        print("  B-spline path: \(pathPoints.count) points")
    }

    /// Extend path incrementally for a new block
    mutating func extendPath(map: ForestMap, blockCoord: BlockCoord,
                             startX: Float, startZ: Float,
                             endX: Float, endZ: Float) -> PathSegment {
        let zMin = Float(blockCoord.bz) * map.blockSize
        let zMax = zMin + map.blockSize

        // Collect trees from this block + neighbors
        let treeCenters = map.treeCenters(zMin: zMin - 3.0, zMax: zMax + 3.0)
        var treeGrid = SpatialGrid(cellSize: 4.0)
        treeGrid.insertAll(treeCenters)

        // Build Voronoi+Dijkstra for this block region
        var points: [(Float, Float)] = treeCenters
        let margin: Float = 3.0
        let spacing: Float = 2.0

        // Boundary points
        let bxMin = pathXMin - margin
        let bxMax = pathXMax + margin
        let bzMin = zMin - margin
        let bzMax = zMax + margin

        var bx = bxMin
        while bx <= bxMax { points.append((bx, bzMin)); bx += spacing }
        bx = bxMin
        while bx <= bxMax { points.append((bx, bzMax)); bx += spacing }
        var bz = bzMin + spacing
        while bz < bzMax { points.append((bxMin, bz)); bz += spacing }
        bz = bzMin + spacing
        while bz < bzMax { points.append((bxMax, bz)); bz += spacing }

        let triangles = bowyerWatson(points: points)

        // Extract Voronoi
        var voronoiVertices: [VoronoiVertex] = []
        var voronoiAdj: [[Int]] = []
        var voronoiEdges: [VoronoiEdge] = []
        var triToVoronoi: [Int: Int] = [:]

        for (ti, tri) in triangles.enumerated() {
            let cx = tri.circumX, cy = tri.circumY
            let clearance = treeGrid.nearestDist(x: cx, z: cy)
            if cx < pathXMin || cx > pathXMax { continue }
            if cy < zMin || cy > zMax { continue }
            if clearance < minClearance * 1.2 { continue }

            let vi = voronoiVertices.count
            voronoiVertices.append(VoronoiVertex(x: cx, y: cy, clearance: clearance))
            voronoiAdj.append([])
            triToVoronoi[ti] = vi
        }

        var edgeToTriangles: [Int64: [Int]] = [:]
        for (ti, tri) in triangles.enumerated() {
            guard triToVoronoi[ti] != nil else { continue }
            for ek in [edgeKey(tri.a, tri.b), edgeKey(tri.b, tri.c), edgeKey(tri.a, tri.c)] {
                edgeToTriangles[ek, default: []].append(ti)
            }
        }

        for (_, tris) in edgeToTriangles {
            if tris.count != 2 { continue }
            guard let vi0 = triToVoronoi[tris[0]], let vi1 = triToVoronoi[tris[1]] else { continue }
            let v0 = voronoiVertices[vi0], v1 = voronoiVertices[vi1]
            let dx = v1.x - v0.x, dy = v1.y - v0.y
            let edgeLen = sqrt(dx * dx + dy * dy)
            if edgeLen < 1e-6 { continue }

            var edgeMinClear: Float = Float.infinity
            for s in 0...5 {
                let t = Float(s) / 5.0
                let c = treeGrid.nearestDist(x: v0.x + t * dx, z: v0.y + t * dy)
                if c < edgeMinClear { edgeMinClear = c }
            }
            if edgeMinClear < minClearance * 1.2 { continue }

            let weight = edgeLen / pow(max(edgeMinClear, 0.01), corridorAlpha)
            let ei = voronoiEdges.count
            voronoiEdges.append(VoronoiEdge(from: vi0, to: vi1, length: edgeLen, minClearance: edgeMinClear, weight: weight))
            voronoiAdj[vi0].append(ei)
            let ei2 = voronoiEdges.count
            voronoiEdges.append(VoronoiEdge(from: vi1, to: vi0, length: edgeLen, minClearance: edgeMinClear, weight: weight))
            voronoiAdj[vi1].append(ei2)
        }

        // Dijkstra from start to end
        let sVi = voronoiVertices.count
        voronoiVertices.append(VoronoiVertex(x: startX, y: startZ, clearance: .infinity))
        voronoiAdj.append([])
        let eVi = voronoiVertices.count
        voronoiVertices.append(VoronoiVertex(x: endX, y: endZ, clearance: .infinity))
        voronoiAdj.append([])

        connectVirtualVertex(sVi, x: startX, z: startZ, vertices: &voronoiVertices, adj: &voronoiAdj, edges: &voronoiEdges, k: 10)
        connectVirtualVertex(eVi, x: endX, z: endZ, vertices: &voronoiVertices, adj: &voronoiAdj, edges: &voronoiEdges, k: 10)

        let n = voronoiVertices.count
        var dist = [Float](repeating: .infinity, count: n)
        var prev = [Int](repeating: -1, count: n)
        dist[sVi] = 0
        var pq = PriorityQueue()
        pq.insert(0, sVi)

        while let (d, u) = pq.extractMin() {
            if d > dist[u] { continue }
            if u == eVi { break }
            for ei in voronoiAdj[u] {
                let edge = voronoiEdges[ei]
                let nd = d + edge.weight
                if nd < dist[edge.to] { dist[edge.to] = nd; prev[edge.to] = u; pq.insert(nd, edge.to) }
            }
        }

        var pathVerts: [(Float, Float)] = []
        if dist[eVi] < .infinity {
            var cur = eVi
            while cur != -1 { pathVerts.append((voronoiVertices[cur].x, voronoiVertices[cur].y)); cur = prev[cur] }
            pathVerts.reverse()
        } else {
            pathVerts = [(startX, startZ), (endX, endZ)]
        }

        // B-spline
        let bsplineResult = evaluateBSplineSegment(controlPoints: pathVerts)

        var segPoints = bsplineResult.points
        var segYaw = bsplineResult.yaw

        // Uniform arc-length resampling to eliminate large gaps
        if segPoints.count >= 2 {
            var totalStepLen: Float = 0
            for i in 1..<segPoints.count {
                let dx = segPoints[i].0 - segPoints[i-1].0
                let dz = segPoints[i].1 - segPoints[i-1].1
                totalStepLen += sqrt(dx * dx + dz * dz)
            }
            let avgStep = totalStepLen / Float(segPoints.count - 1)
            let resampled = resampleUniform(points: segPoints, stepSize: avgStep)
            segPoints = resampled.points
            segYaw = resampled.yaw
        }

        // Compute segment length
        var segLength: Float = 0
        for i in 1..<segPoints.count {
            let dx = segPoints[i].0 - segPoints[i-1].0
            let dz = segPoints[i].1 - segPoints[i-1].1
            segLength += sqrt(dx * dx + dz * dz)
        }

        let segment = PathSegment(points: segPoints, yaw: segYaw, length: segLength)
        segments.append(segment)

        // Append to global path
        pathPoints.append(contentsOf: segPoints)
        pathYaw.append(contentsOf: segYaw)
        totalLength += segLength
        buildArcLength()

        return segment
    }

    /// Evaluate position and heading at a given world distance along the path
    func evaluate(distance: Float) -> (x: Float, z: Float, yaw: Float) {
        guard pathPoints.count >= 2, arcLength.count == pathPoints.count else {
            return (0, 0, 0)
        }

        let d = min(max(distance, 0), totalLength)

        // Binary search for the right segment
        var lo = 0, hi = arcLength.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if arcLength[mid] < d { lo = mid + 1 } else { hi = mid }
        }

        let idx = max(0, lo - 1)
        let nextIdx = min(idx + 1, pathPoints.count - 1)

        let segLen = arcLength[nextIdx] - arcLength[idx]
        let frac = segLen > 1e-6 ? (d - arcLength[idx]) / segLen : 0

        let x = pathPoints[idx].0 + (pathPoints[nextIdx].0 - pathPoints[idx].0) * frac
        let z = pathPoints[idx].1 + (pathPoints[nextIdx].1 - pathPoints[idx].1) * frac

        // Interpolate yaw with angle wrapping
        var dyaw = pathYaw[nextIdx] - pathYaw[idx]
        if dyaw > .pi { dyaw -= 2.0 * .pi }
        if dyaw < -.pi { dyaw += 2.0 * .pi }
        let yaw = pathYaw[idx] + dyaw * frac

        return (x, z, yaw)
    }

    /// Evaluate by progress (0..1)
    func evaluateByProgress(_ t: Float) -> (x: Float, z: Float, yaw: Float) {
        return evaluate(distance: t * totalLength)
    }

    /// Sample path at N steps
    func samplePath(steps: Int = 1000) -> [(Float, Float)] {
        guard pathPoints.count >= 2 else { return [] }
        var samples: [(Float, Float)] = []
        samples.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let (x, z, _) = evaluateByProgress(t)
            samples.append((x, z))
        }
        return samples
    }

    // MARK: - Private: B-spline

    private mutating func evaluateBSpline(controlPoints: [(Float, Float)]) {
        guard controlPoints.count >= 2 else {
            pathPoints = controlPoints
            pathYaw = [Float](repeating: 0, count: controlPoints.count)
            return
        }

        var cps = controlPoints
        cps.insert(cps[0], at: 0)
        cps.insert(cps[0], at: 0)
        cps.append(cps[cps.count - 1])
        cps.append(cps[cps.count - 1])

        let numSegments = cps.count - 3
        let totalPathLength = estimatePathLength(controlPoints)
        let samplesPerSegment = max(10, Int(totalPathLength / Float(numSegments) / 0.02))

        pathPoints = []
        pathYaw = []
        pathPoints.reserveCapacity(numSegments * samplesPerSegment + 1)
        pathYaw.reserveCapacity(numSegments * samplesPerSegment + 1)

        for seg in 0..<numSegments {
            let p0 = cps[seg], p1 = cps[seg + 1], p2 = cps[seg + 2], p3 = cps[seg + 3]
            let endS = (seg == numSegments - 1) ? samplesPerSegment : samplesPerSegment - 1
            for si in 0...endS {
                let s = Float(si) / Float(samplesPerSegment)
                let (pos, tan) = bsplineEval(p0, p1, p2, p3, s)
                pathPoints.append(pos)
                pathYaw.append(atan2(tan.0, tan.1))
            }
        }
    }

    /// Evaluate B-spline for a segment.
    private func evaluateBSplineSegment(controlPoints: [(Float, Float)])
        -> (points: [(Float, Float)], yaw: [Float]) {

        guard controlPoints.count >= 2 else {
            return (controlPoints, [Float](repeating: 0, count: controlPoints.count))
        }

        var cps = controlPoints
        cps.insert(cps[0], at: 0)
        cps.insert(cps[0], at: 0)
        cps.append(cps[cps.count - 1])
        cps.append(cps[cps.count - 1])

        let numSegments = cps.count - 3
        guard numSegments > 0 else {
            return (controlPoints, [Float](repeating: 0, count: controlPoints.count))
        }
        let totalLen = estimatePathLength(controlPoints)
        let samplesPerSegment = max(10, Int(totalLen / Float(numSegments) / 0.02))

        var points: [(Float, Float)] = []
        var yaw: [Float] = []

        for seg in 0..<numSegments {
            let p0 = cps[seg], p1 = cps[seg + 1], p2 = cps[seg + 2], p3 = cps[seg + 3]
            let endS = (seg == numSegments - 1) ? samplesPerSegment : samplesPerSegment - 1
            for si in 0...endS {
                let s = Float(si) / Float(samplesPerSegment)
                let (pos, tan) = bsplineEval(p0, p1, p2, p3, s)
                points.append(pos)
                yaw.append(atan2(tan.0, tan.1))
            }
        }

        return (points, yaw)
    }

    /// B-spline basis evaluation: returns (position, tangent)
    private func bsplineEval(_ p0: (Float, Float), _ p1: (Float, Float),
                              _ p2: (Float, Float), _ p3: (Float, Float),
                              _ s: Float) -> ((Float, Float), (Float, Float)) {
        let s2 = s * s, s3 = s2 * s

        let b0 = (-s3 + 3.0 * s2 - 3.0 * s + 1.0) / 6.0
        let b1 = (3.0 * s3 - 6.0 * s2 + 4.0) / 6.0
        let b2 = (-3.0 * s3 + 3.0 * s2 + 3.0 * s + 1.0) / 6.0
        let b3 = s3 / 6.0

        let x = b0 * p0.0 + b1 * p1.0 + b2 * p2.0 + b3 * p3.0
        let z = b0 * p0.1 + b1 * p1.1 + b2 * p2.1 + b3 * p3.1

        let d0 = (-3.0 * s2 + 6.0 * s - 3.0) / 6.0
        let d1 = (9.0 * s2 - 12.0 * s) / 6.0
        let d2 = (-9.0 * s2 + 6.0 * s + 3.0) / 6.0
        let d3 = (3.0 * s2) / 6.0

        let tx = d0 * p0.0 + d1 * p1.0 + d2 * p2.0 + d3 * p3.0
        let tz = d0 * p0.1 + d1 * p1.1 + d2 * p2.1 + d3 * p3.1

        return ((x, z), (tx, tz))
    }

    // MARK: - Private: Bowyer-Watson

    private func bowyerWatson(points: [(Float, Float)]) -> [DelaunayTriangle] {
        var minX: Float = .infinity, maxX: Float = -.infinity
        var minY: Float = .infinity, maxY: Float = -.infinity
        for (x, y) in points {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
        let dmax = max(maxX - minX, maxY - minY)
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2

        let n = points.count
        var allPoints = points
        allPoints.append((midX - 20.0 * dmax, midY - dmax))
        allPoints.append((midX + 20.0 * dmax, midY - dmax))
        allPoints.append((midX, midY + 20.0 * dmax))

        var triangles = [makeTriangle(n, n + 1, n + 2, points: allPoints)]

        for pi in 0..<n {
            let px = allPoints[pi].0, py = allPoints[pi].1

            var badIndices: [Int] = []
            for (ti, tri) in triangles.enumerated() {
                let dx = px - tri.circumX, dy = py - tri.circumY
                if dx * dx + dy * dy < tri.circumR2 { badIndices.append(ti) }
            }

            var edgeCount: [Int64: Int] = [:]
            var edgeEndpoints: [Int64: (Int, Int)] = [:]
            for ti in badIndices {
                let tri = triangles[ti]
                for (ea, eb) in [(tri.a, tri.b), (tri.b, tri.c), (tri.a, tri.c)] {
                    let ek = edgeKey(ea, eb)
                    edgeCount[ek, default: 0] += 1
                    edgeEndpoints[ek] = (ea, eb)
                }
            }

            let boundary = edgeCount.filter { $0.value == 1 }.map { edgeEndpoints[$0.key]! }
            for ti in badIndices.sorted().reversed() { triangles.remove(at: ti) }
            for (ea, eb) in boundary { triangles.append(makeTriangle(pi, ea, eb, points: allPoints)) }
        }

        return triangles.filter { $0.a < n && $0.b < n && $0.c < n }
    }

    private func makeTriangle(_ a: Int, _ b: Int, _ c: Int, points: [(Float, Float)]) -> DelaunayTriangle {
        let ax = points[a].0, ay = points[a].1
        let bx = points[b].0, by = points[b].1
        let cx = points[c].0, cy = points[c].1

        let d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        let circumX: Float, circumY: Float
        if abs(d) < 1e-10 {
            circumX = (ax + bx + cx) / 3.0; circumY = (ay + by + cy) / 3.0
        } else {
            let a2 = ax * ax + ay * ay, b2 = bx * bx + by * by, c2 = cx * cx + cy * cy
            circumX = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
            circumY = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
        }
        let rdx = ax - circumX, rdy = ay - circumY
        return DelaunayTriangle(a: a, b: b, c: c, circumX: circumX, circumY: circumY, circumR2: rdx * rdx + rdy * rdy)
    }

    private func edgeKey(_ a: Int, _ b: Int) -> Int64 {
        Int64(min(a, b)) * 1_000_000 + Int64(max(a, b))
    }

    // MARK: - Private: Virtual vertex connections

    private func connectVirtualVertex(
        _ vi: Int, x: Float, z: Float,
        vertices: inout [VoronoiVertex], adj: inout [[Int]],
        edges: inout [VoronoiEdge], k: Int
    ) {
        let realCount = vertices.count - 2
        guard realCount > 0 else { return }

        var distances: [(Float, Int)] = []
        for i in 0..<realCount {
            let v = vertices[i]
            let dx = v.x - x, dy = v.y - z
            distances.append((sqrt(dx * dx + dy * dy), i))
        }
        distances.sort { $0.0 < $1.0 }

        for i in 0..<min(k, distances.count) {
            let (d, ni) = distances[i]
            let ei1 = edges.count
            edges.append(VoronoiEdge(from: vi, to: ni, length: d, minClearance: .infinity, weight: d))
            adj[vi].append(ei1)
            let ei2 = edges.count
            edges.append(VoronoiEdge(from: ni, to: vi, length: d, minClearance: .infinity, weight: d))
            adj[ni].append(ei2)
        }
    }

    // MARK: - Private: Uniform resampling

    /// Resample path points at uniform arc-length intervals to prevent large gaps
    /// that cause the camera to "cut corners" through trees during linear interpolation.
    private func resampleUniform(points: [(Float, Float)], stepSize: Float)
        -> (points: [(Float, Float)], yaw: [Float]) {

        guard points.count >= 2 else {
            return (points, points.count > 0 ? [Float](repeating: 0, count: points.count) : [])
        }

        // Compute cumulative arc lengths
        var cumLen: [Float] = [0]
        cumLen.reserveCapacity(points.count)
        for i in 1..<points.count {
            let dx = points[i].0 - points[i-1].0
            let dz = points[i].1 - points[i-1].1
            cumLen.append(cumLen[i-1] + sqrt(dx * dx + dz * dz))
        }
        let totalLen = cumLen.last!
        guard totalLen > 1e-6 else {
            return (points, [Float](repeating: 0, count: points.count))
        }

        // Generate uniformly spaced samples
        let numSamples = max(2, Int(ceil(totalLen / stepSize)) + 1)
        let actualStep = totalLen / Float(numSamples - 1)

        var result: [(Float, Float)] = []
        var resultYaw: [Float] = []
        result.reserveCapacity(numSamples)

        var srcIdx = 0
        for i in 0..<numSamples {
            let targetDist = Float(i) * actualStep

            // Advance srcIdx to find the segment containing targetDist
            while srcIdx < points.count - 2 && cumLen[srcIdx + 1] < targetDist {
                srcIdx += 1
            }

            let segLen = cumLen[srcIdx + 1] - cumLen[srcIdx]
            let t = segLen > 1e-6 ? min(max((targetDist - cumLen[srcIdx]) / segLen, 0), 1) : 0

            let x = points[srcIdx].0 + t * (points[srcIdx + 1].0 - points[srcIdx].0)
            let z = points[srcIdx].1 + t * (points[srcIdx + 1].1 - points[srcIdx].1)
            result.append((x, z))
        }

        // Recompute yaw from resampled points
        for i in 0..<result.count {
            if i < result.count - 1 {
                let dx = result[i + 1].0 - result[i].0
                let dz = result[i + 1].1 - result[i].1
                resultYaw.append(atan2(dx, dz))
            } else {
                resultYaw.append(resultYaw.last ?? 0)
            }
        }

        return (result, resultYaw)
    }

    // MARK: - Private: Arc-length

    private mutating func buildArcLength() {
        arcLength = [0]
        arcLength.reserveCapacity(pathPoints.count)
        var cumulative: Float = 0
        for i in 1..<pathPoints.count {
            let dx = pathPoints[i].0 - pathPoints[i-1].0
            let dz = pathPoints[i].1 - pathPoints[i-1].1
            cumulative += sqrt(dx * dx + dz * dz)
            arcLength.append(cumulative)
        }
        totalLength = cumulative
    }

    private func estimatePathLength(_ points: [(Float, Float)]) -> Float {
        var total: Float = 0
        for i in 1..<points.count {
            let dx = points[i].0 - points[i-1].0
            let dz = points[i].1 - points[i-1].1
            total += sqrt(dx * dx + dz * dz)
        }
        return total
    }
}
