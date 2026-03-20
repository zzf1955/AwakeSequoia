import Foundation
import Metal
import simd

// MARK: - EngineConfig

struct EngineConfig: Decodable {
    var width: Int
    var height: Int
    var fps: Int

    var fovDegrees: Float
    var pitchDegrees: Float
    var cameraHeight: Float
    var nearPlane: Float
    var farPlane: Float

    var speedPercent: Float

    var dayProgress: Float
    var dayProgressSpeed: Float
    var gradientName: String?

    var dimmingGradientAmount: Float
    var gradientUVOffset: Float
    var gradientUVScale: Float
    var gradientWashout: Float

    var treeDensity: Float
    var blockWidth: Float
    var blockLength: Float
    var minClearance: Float
    var corridorAlpha: Float
    var seed: UInt64
    var startClearHalfWidth: Float
    var startClearDepth: Float

    var lookaheadBlocks: Int
    var trailBlocks: Int

    // Sway
    var swayAmplitude: Float
    var swaySpeed: Float

    // Output
    var outputDir: String      // base directory for all output (relative to CWD / project root)
    var duration: Float        // video duration in seconds

    // Debug
    var debugFrameCount: Int   // number of perspective frames rendered in debug mode
    var debugTopDownBlocks: Int  // number of consecutive blocks shown in top-down views

    init() {
        width = 3840; height = 2160; fps = 60
        fovDegrees = 45.0; pitchDegrees = 60.0; cameraHeight = 0.01
        nearPlane = 0.001; farPlane = 200.0
        speedPercent = 50.0
        dayProgress = 0.5; dayProgressSpeed = 0.0; gradientName = "solar noon"
        dimmingGradientAmount = 0.0; gradientUVOffset = 0.3
        gradientUVScale = 0.7; gradientWashout = 0.15
        treeDensity = 1.5625; blockWidth = 13.0; blockLength = 16.0
        minClearance = 0.3; corridorAlpha = 2.0; seed = 42
        startClearHalfWidth = 1.0; startClearDepth = 2.0
        lookaheadBlocks = 5; trailBlocks = 2
        swayAmplitude = 3.0; swaySpeed = 1.0
        outputDir = "output"; duration = 30.0
        debugFrameCount = 5; debugTopDownBlocks = 3
    }

    init(from decoder: Decoder) throws {
        let d = EngineConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? d.width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? d.height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        fovDegrees = try c.decodeIfPresent(Float.self, forKey: .fovDegrees) ?? d.fovDegrees
        pitchDegrees = try c.decodeIfPresent(Float.self, forKey: .pitchDegrees) ?? d.pitchDegrees
        cameraHeight = try c.decodeIfPresent(Float.self, forKey: .cameraHeight) ?? d.cameraHeight
        nearPlane = try c.decodeIfPresent(Float.self, forKey: .nearPlane) ?? d.nearPlane
        farPlane = try c.decodeIfPresent(Float.self, forKey: .farPlane) ?? d.farPlane
        speedPercent = try c.decodeIfPresent(Float.self, forKey: .speedPercent) ?? d.speedPercent
        dayProgress = try c.decodeIfPresent(Float.self, forKey: .dayProgress) ?? d.dayProgress
        dayProgressSpeed = try c.decodeIfPresent(Float.self, forKey: .dayProgressSpeed) ?? d.dayProgressSpeed
        gradientName = try c.decodeIfPresent(String.self, forKey: .gradientName) ?? d.gradientName
        dimmingGradientAmount = try c.decodeIfPresent(Float.self, forKey: .dimmingGradientAmount) ?? d.dimmingGradientAmount
        gradientUVOffset = try c.decodeIfPresent(Float.self, forKey: .gradientUVOffset) ?? d.gradientUVOffset
        gradientUVScale = try c.decodeIfPresent(Float.self, forKey: .gradientUVScale) ?? d.gradientUVScale
        gradientWashout = try c.decodeIfPresent(Float.self, forKey: .gradientWashout) ?? d.gradientWashout
        treeDensity = try c.decodeIfPresent(Float.self, forKey: .treeDensity) ?? d.treeDensity
        blockWidth = try c.decodeIfPresent(Float.self, forKey: .blockWidth) ?? d.blockWidth
        blockLength = try c.decodeIfPresent(Float.self, forKey: .blockLength) ?? d.blockLength
        minClearance = try c.decodeIfPresent(Float.self, forKey: .minClearance) ?? d.minClearance
        corridorAlpha = try c.decodeIfPresent(Float.self, forKey: .corridorAlpha) ?? d.corridorAlpha
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? d.seed
        startClearHalfWidth = try c.decodeIfPresent(Float.self, forKey: .startClearHalfWidth) ?? d.startClearHalfWidth
        startClearDepth = try c.decodeIfPresent(Float.self, forKey: .startClearDepth) ?? d.startClearDepth
        lookaheadBlocks = try c.decodeIfPresent(Int.self, forKey: .lookaheadBlocks) ?? d.lookaheadBlocks
        trailBlocks = try c.decodeIfPresent(Int.self, forKey: .trailBlocks) ?? d.trailBlocks
        swayAmplitude = try c.decodeIfPresent(Float.self, forKey: .swayAmplitude) ?? d.swayAmplitude
        swaySpeed = try c.decodeIfPresent(Float.self, forKey: .swaySpeed) ?? d.swaySpeed
        outputDir = try c.decodeIfPresent(String.self, forKey: .outputDir) ?? d.outputDir
        duration = try c.decodeIfPresent(Float.self, forKey: .duration) ?? d.duration
        debugFrameCount = try c.decodeIfPresent(Int.self, forKey: .debugFrameCount) ?? d.debugFrameCount
        debugTopDownBlocks = try c.decodeIfPresent(Int.self, forKey: .debugTopDownBlocks) ?? d.debugTopDownBlocks
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, fps
        case fovDegrees, pitchDegrees, cameraHeight, nearPlane, farPlane
        case speedPercent
        case dayProgress, dayProgressSpeed, gradientName
        case dimmingGradientAmount, gradientUVOffset, gradientUVScale, gradientWashout
        case treeDensity, blockWidth, blockLength, minClearance, corridorAlpha, seed
        case startClearHalfWidth, startClearDepth
        case lookaheadBlocks, trailBlocks
        case swayAmplitude, swaySpeed
        case outputDir, duration
        case debugFrameCount, debugTopDownBlocks
    }
}

func loadEngineConfig(path: String) -> EngineConfig {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        print("  Warning: Could not read config file: \(path), using defaults")
        return EngineConfig()
    }
    do {
        return try JSONDecoder().decode(EngineConfig.self, from: data)
    } catch {
        print("  Error parsing config JSON: \(error), using defaults")
        return EngineConfig()
    }
}

// MARK: - TimeMode

enum TimeMode: String {
    case realTime   // follow system clock
    case light      // fixed daytime
    case dark       // 12-hour offset (nighttime)
}

// MARK: - WallpaperEngine

class WallpaperEngine {

    // MARK: Internal components

    let renderer: ForestRenderer
    private(set) var map: ForestMap
    private let config: EngineConfig
    var planner: PathPlanner
    var camera: CameraController

    // MARK: Core state

    private(set) var frameIndex: Int = 0
    private(set) var currentDistance: Float = 0
    private var lastCameraState: CameraState?

    // MARK: Frontier state

    private var frontierBlockZ: Int = 0
    private var tailBlockZ: Int = 0
    private var lookaheadBlocks: Int
    private var trailBlocks: Int
    private var lastPathEndX: Float = 0
    private var lastPathEndZ: Float = 0

    // MARK: Configurable parameters (hot-swappable)

    var fps: Int
    var speedPercent: Float
    var dayProgress: Float
    var dayProgressSpeed: Float
    var gradientName: String?
    var isPaused: Bool = false
    var speedMultiplier: Float = 1.0

    var timeMode: TimeMode = .light
    var baseDayProgress: Float = 0.5

    /// Smooth transition state for dayProgress changes
    private var dayProgressTransition: (from: Float, to: Float, elapsed: Float, duration: Float)?

    /// Transition duration in seconds for color changes
    var transitionDuration: Float = 2.0

    /// Start a smooth transition of dayProgress to a new target value
    func transitionDayProgress(to target: Float) {
        dayProgressTransition = (from: dayProgress, to: target, elapsed: 0, duration: transitionDuration)
    }

    var swayAmplitude: Float {
        get { camera.swayAmplitude }
        set { camera.swayAmplitude = newValue }
    }
    var swaySpeed: Float {
        get { camera.swaySpeed }
        set { camera.swaySpeed = newValue }
    }

    var pitchDegrees: Float {
        get { camera.pitchDegrees }
        set { camera.pitchDegrees = newValue }
    }
    var fovDegrees: Float {
        get { camera.fovDegrees }
        set { camera.fovDegrees = newValue; cachedProjMatrix = nil }
    }
    var cameraHeight: Float {
        get { camera.height }
        set { camera.height = newValue }
    }
    var nearPlane: Float {
        get { camera.nearPlane }
        set { camera.nearPlane = newValue; cachedProjMatrix = nil }
    }
    var farPlane: Float {
        get { camera.farPlane }
        set { camera.farPlane = newValue; cachedProjMatrix = nil }
    }

    // MARK: Derived state

    var currentTime: Float { Float(frameIndex) / Float(fps) }
    var cameraPosition: SIMD3<Float> { lastCameraState?.position ?? SIMD3(0, 0, 0) }
    var pathTotalLength: Float { planner.totalLength }

    private var aspect: Float { Float(renderer.width) / Float(renderer.height) }
    private var cachedProjMatrix: float4x4?
    private var projMatrix: float4x4 {
        if let cached = cachedProjMatrix { return cached }
        let m = camera.projectionMatrix(aspect: aspect)
        cachedProjMatrix = m
        return m
    }

    // MARK: Init

    init(config: EngineConfig, device: MTLDevice? = nil) throws {
        self.config = config
        let dev = device ?? MTLCreateSystemDefaultDevice()!
        print("Metal device: \(dev.name)")

        self.renderer = try ForestRenderer(device: dev, width: config.width, height: config.height)

        renderer.dimmingGradientAmount = config.dimmingGradientAmount
        renderer.gradientUVOffset = config.gradientUVOffset
        renderer.gradientUVScale = config.gradientUVScale
        renderer.gradientWashout = config.gradientWashout

        self.map = ForestMap(seed: config.seed)
        map.blockWidth = config.blockWidth
        map.blockSize = config.blockLength
        map.forestDensity = config.treeDensity
        map.minClearance = config.minClearance
        map.startClearZone = (config.startClearHalfWidth, config.startClearDepth)

        var planner = PathPlanner()
        planner.minClearance = config.minClearance
        planner.corridorAlpha = config.corridorAlpha
        self.planner = planner

        var cam = CameraController()
        cam.height = config.cameraHeight
        cam.pitchDegrees = config.pitchDegrees
        cam.fovDegrees = config.fovDegrees
        cam.nearPlane = config.nearPlane
        cam.farPlane = config.farPlane
        cam.swayAmplitude = config.swayAmplitude
        cam.swaySpeed = config.swaySpeed
        self.camera = cam

        self.fps = config.fps
        self.speedPercent = config.speedPercent
        self.dayProgress = config.dayProgress
        self.dayProgressSpeed = config.dayProgressSpeed
        self.baseDayProgress = config.dayProgress
        self.gradientName = config.gradientName
        self.lookaheadBlocks = config.lookaheadBlocks
        self.trailBlocks = config.trailBlocks

        bootstrap()
    }

    // MARK: - Bootstrap

    /// Load initial blocks and generate the first path segments
    private func bootstrap() {
        let startBZ = -1
        tailBlockZ = startBZ

        for bz in startBZ...(lookaheadBlocks) {
            map.loadBlock(BlockCoord(bx: 0, bz: bz))
        }

        // Generate initial path through loaded blocks using extendPath per-block
        lastPathEndX = 0
        lastPathEndZ = 0

        for bz in 0...lookaheadBlocks {
            let coord = BlockCoord(bx: 0, bz: bz)
            let endZ = Float(bz + 1) * map.blockSize
            planner.extendPath(
                map: map, blockCoord: coord,
                startX: lastPathEndX, startZ: lastPathEndZ,
                endX: 0, endZ: endZ
            )
            removeCollidingTrees(blockCoord: coord)
            if bz == 0 {
                removeCollidingTrees(blockCoord: BlockCoord(bx: 0, bz: -1))
            }
            if let lastPt = planner.pathPoints.last {
                lastPathEndX = lastPt.0
                lastPathEndZ = lastPt.1
            }
        }
        frontierBlockZ = lookaheadBlocks + 1

        print("  Bootstrap: \(map.blocks.count) blocks loaded, path length = \(String(format: "%.1f", planner.totalLength))")
        verifyPath()
    }

    // MARK: - Path Verification

    /// Static check: detect jumps (discontinuities) and tree collisions in pathPoints
    private func verifyPath() {
        let points = planner.pathPoints
        guard points.count >= 2 else { return }

        // Compute average step size
        var totalStep: Float = 0
        for i in 1..<points.count {
            let dx = points[i].0 - points[i-1].0
            let dz = points[i].1 - points[i-1].1
            totalStep += sqrt(dx * dx + dz * dz)
        }
        let avgStep = totalStep / Float(points.count - 1)
        let jumpThreshold = avgStep * 3.0

        // Detect path jumps
        var jumpCount = 0
        var maxJump: Float = 0
        for i in 1..<points.count {
            let dx = points[i].0 - points[i-1].0
            let dz = points[i].1 - points[i-1].1
            let step = sqrt(dx * dx + dz * dz)
            if step > jumpThreshold {
                jumpCount += 1
                if step > maxJump { maxJump = step }
            }
        }

        // Check path points against nearest tree
        var minTreeDist: Float = .infinity
        var collisionCount = 0
        for pt in points {
            let d = map.nearestTreeDist(x: pt.0, z: pt.1)
            if d < minTreeDist { minTreeDist = d }
            if d < planner.minClearance { collisionCount += 1 }
        }

        // Check evaluate() collisions
        let totalFrames = Int(30.0 * Float(fps))
        let distPerFrame = (speedPercent / 100.0) * map.blockSize / Float(fps)
        var evalCollisions = 0
        for f in 0..<totalFrames {
            let dist = Float(f) * distPerFrame
            let (ex, ez, _) = planner.evaluate(distance: dist)
            let d = map.nearestTreeDist(x: ex, z: ez)
            if d < planner.minClearance { evalCollisions += 1 }
        }

        print("  Path verify: \(points.count) pts, avgStep=\(String(format: "%.4f", avgStep)), jumps(>3x)=\(jumpCount), maxJump=\(String(format: "%.4f", maxJump)), minTreeDist=\(String(format: "%.4f", minTreeDist)), collisions=\(collisionCount), evalCollisions=\(evalCollisions)")

        // Print all collision details
        if collisionCount > 0 {
            print("  --- pathPoint collisions ---")
            for (i, pt) in points.enumerated() {
                let (d, tx, tz) = map.nearestTree(x: pt.0, z: pt.1)
                if d < planner.minClearance {
                    print("    idx=\(i) path=(\(String(format: "%.3f", pt.0)),\(String(format: "%.3f", pt.1))) tree=(\(String(format: "%.3f", tx)),\(String(format: "%.3f", tz))) dist=\(String(format: "%.4f", d))")
                }
            }
        }
        if evalCollisions > 0 {
            print("  --- evaluate() collisions ---")
            for f in 0..<totalFrames {
                let dist = Float(f) * distPerFrame
                let (ex, ez, _) = planner.evaluate(distance: dist)
                let (d, tx, tz) = map.nearestTree(x: ex, z: ez)
                if d < planner.minClearance {
                    print("    frame=\(f) cam=(\(String(format: "%.3f", ex)),\(String(format: "%.3f", ez))) tree=(\(String(format: "%.3f", tx)),\(String(format: "%.3f", tz))) dist=\(String(format: "%.4f", d))")
                }
            }
        }
    }

    // MARK: - Interface A: Auto-advance

    /// Render next frame, automatically advancing distance + dayProgress + frontier.
    func renderNextFrame() -> MTLTexture? {
        let result = renderCurrentState()
        if !isPaused {
            advanceState()
        }
        return result
    }

    // MARK: - Interface B: External override

    /// Render at a specific distance and dayProgress (for seek / debug).
    /// Ensures frontier is ready for the requested distance.
    func render(distance: Float, dayProgress: Float) -> MTLTexture? {
        ensureFrontier(forDistance: distance)
        return renderAt(distance: distance, dayProgress: dayProgress)
    }

    // MARK: - Control

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func reset() {
        frameIndex = 0
        currentDistance = 0
        lastCameraState = nil
        cachedProjMatrix = nil
        dayProgress = baseDayProgress

        // Recreate map with original seed for identical scene
        map = ForestMap(seed: config.seed)
        map.blockWidth = config.blockWidth
        map.blockSize = config.blockLength
        map.forestDensity = config.treeDensity
        map.minClearance = config.minClearance
        map.startClearZone = (config.startClearHalfWidth, config.startClearDepth)

        // Recreate planner with full config
        planner = PathPlanner()
        planner.minClearance = config.minClearance
        planner.corridorAlpha = config.corridorAlpha

        lastPathEndX = 0
        lastPathEndZ = 0
        frontierBlockZ = 0
        tailBlockZ = 0

        bootstrap()
    }

    // MARK: - State advancement

    private func advanceState() {
        let distPerFrame = (speedPercent / 100.0) * map.blockSize / Float(fps) * speedMultiplier
        currentDistance += distPerFrame

        // Handle smooth dayProgress transition if active
        if var transition = dayProgressTransition {
            transition.elapsed += 1.0 / Float(fps)
            let t = min(transition.elapsed / transition.duration, 1.0)
            // Ease-in-out (smoothstep)
            let smooth = t * t * (3.0 - 2.0 * t)

            // Shortest-path circular interpolation on [0, 1)
            var delta = transition.to - transition.from
            if delta > 0.5 { delta -= 1.0 }
            if delta < -0.5 { delta += 1.0 }
            var progress = transition.from + delta * smooth
            if progress < 0 { progress += 1.0 }
            if progress >= 1.0 { progress -= 1.0 }
            dayProgress = progress

            if t >= 1.0 {
                dayProgressTransition = nil
            } else {
                dayProgressTransition = transition
            }
        } else {
            // Normal time mode advancement (no transition in progress)
            switch timeMode {
            case .realTime:
                let now = Date()
                let cal = Calendar.current
                let hour = Float(cal.component(.hour, from: now))
                let minute = Float(cal.component(.minute, from: now))
                let second = Float(cal.component(.second, from: now))
                dayProgress = (hour + minute / 60.0 + second / 3600.0) / 24.0
            case .light:
                if dayProgressSpeed != 0 {
                    dayProgress += dayProgressSpeed / Float(fps)
                    dayProgress = dayProgress.truncatingRemainder(dividingBy: 1.0)
                    if dayProgress < 0 { dayProgress += 1.0 }
                }
            case .dark:
                if dayProgressSpeed != 0 {
                    baseDayProgress += dayProgressSpeed / Float(fps)
                    baseDayProgress = baseDayProgress.truncatingRemainder(dividingBy: 1.0)
                    if baseDayProgress < 0 { baseDayProgress += 1.0 }
                }
                dayProgress = (baseDayProgress + 0.5).truncatingRemainder(dividingBy: 1.0)
            }
        }

        updateFrontier()
        frameIndex += 1
    }

    // MARK: - Frontier management

    private func updateFrontier() {
        let (_, _, _) = planner.evaluate(distance: currentDistance)
        let camZ = cameraZForDistance(currentDistance)
        let cameraBlockZ = Int(floor(camZ / map.blockSize))

        // Load ahead
        while frontierBlockZ <= cameraBlockZ + lookaheadBlocks {
            let coord = BlockCoord(bx: 0, bz: frontierBlockZ)
            map.loadBlock(coord)

            let endZ = Float(frontierBlockZ + 1) * map.blockSize
            planner.extendPath(
                map: map, blockCoord: coord,
                startX: lastPathEndX, startZ: lastPathEndZ,
                endX: 0, endZ: endZ
            )
            removeCollidingTrees(blockCoord: coord)
            if let lastPt = planner.pathPoints.last {
                lastPathEndX = lastPt.0
                lastPathEndZ = lastPt.1
            }
            frontierBlockZ += 1
        }

        // Unload behind
        while tailBlockZ < cameraBlockZ - trailBlocks {
            map.unloadBlock(BlockCoord(bx: 0, bz: tailBlockZ))
            tailBlockZ += 1
        }
    }

    private func ensureFrontier(forDistance distance: Float) {
        let camZ = cameraZForDistance(distance)
        let cameraBlockZ = Int(floor(camZ / map.blockSize))

        while frontierBlockZ <= cameraBlockZ + lookaheadBlocks {
            let coord = BlockCoord(bx: 0, bz: frontierBlockZ)
            map.loadBlock(coord)
            let endZ = Float(frontierBlockZ + 1) * map.blockSize
            planner.extendPath(
                map: map, blockCoord: coord,
                startX: lastPathEndX, startZ: lastPathEndZ,
                endX: 0, endZ: endZ
            )
            removeCollidingTrees(blockCoord: coord)
            if let lastPt = planner.pathPoints.last {
                lastPathEndX = lastPt.0
                lastPathEndZ = lastPt.1
            }
            frontierBlockZ += 1
        }
    }

    /// Remove trees that collide with the planned path in a block
    private func removeCollidingTrees(blockCoord: BlockCoord) {
        guard let block = map.blocks[blockCoord] else { return }
        let pathPts = planner.pathPoints.filter { $0.1 >= block.worldZMin && $0.1 <= block.worldZMax }
        guard !pathPts.isEmpty else { return }
        map.removeTreesNearPath(blockCoord: blockCoord, pathPoints: pathPts, clearance: planner.minClearance)
    }

    private func cameraZForDistance(_ distance: Float) -> Float {
        let (_, z, _) = planner.evaluate(distance: distance)
        return z
    }

    // MARK: - Rendering

    func renderCurrentState() -> MTLTexture? {
        return renderAt(distance: currentDistance, dayProgress: dayProgress)
    }

    private func renderAt(distance: Float, dayProgress: Float) -> MTLTexture? {
        let state = camera.evaluate(planner: planner, distance: distance, aspect: aspect)
        lastCameraState = state

        let camZ = state.position.z
        let instances = collectInstances(zMin: camZ - 5.0, zMax: camZ + 100.0)

        return renderer.render(
            camera: state, projMatrix: projMatrix,
            forestInstances: instances,
            dayProgress: dayProgress, gradientName: gradientName
        )
    }

    private func collectInstances(zMin: Float, zMax: Float) -> [InstanceData] {
        return map.instancesInRange(zMin: zMin, zMax: zMax).map { $0.toGPU() }
    }
}
