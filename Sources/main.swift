import Foundation
import Metal
import MetalKit
import simd
import ImageIO
import CoreGraphics
import AppKit
import QuartzCore

// MARK: - Configuration

struct Config {
    var width: Int? = nil
    var height: Int? = nil
    var fps: Int? = nil
    var duration: Float? = nil
    var outputPath: String? = nil
    var startHour: Float? = nil
    var endHour: Float? = nil
    var debugStep: Int = 0
    var topDown: Bool = false
    var configPath: String = "render_config.json"
    var liveMode: Bool = false
}

func parseArgs() -> Config {
    var config = Config()
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--width", "-w":
            i += 1; config.width = Int(args[i])
        case "--height", "-h":
            i += 1; config.height = Int(args[i])
        case "--fps":
            i += 1; config.fps = Int(args[i])
        case "--duration", "-d":
            i += 1; config.duration = Float(args[i])
        case "--output", "-o":
            i += 1; config.outputPath = args[i]
        case "--start-hour":
            i += 1; config.startHour = Float(args[i])
        case "--end-hour":
            i += 1; config.endHour = Float(args[i])
        case "--debug-step":
            i += 1; config.debugStep = Int(args[i]) ?? 0
        case "--top-down":
            config.topDown = true
        case "--live":
            config.liveMode = true
        case "--config":
            i += 1; config.configPath = args[i]
        case "--help":
            printUsage()
            exit(0)
        default:
            print("Unknown argument: \(args[i])")
            printUsage()
            exit(1)
        }
        i += 1
    }
    return config
}

func printUsage() {
    print("""
    AwakeSequoia - Render macOS Sequoia wallpaper animation

    Usage: AwakeSequoia [options]

    Options:
      --width, -w <N>        Output width (default: from config)
      --height, -h <N>       Output height (default: from config)
      --fps <N>              Frames per second (default: from config)
      --duration, -d <N>     Duration in seconds (default: from config)
      --output, -o <path>    Output file path (default: <outputDir>/sequoia_wallpaper.mov)
      --start-hour <N>       Start time of day 0-24 (default: use config dayProgress)
      --end-hour <N>         End time of day 0-24 (default: use config dayProgress)
      --debug-step <N>       Debug: output block top-down views (block_0.png, block_0_1.png)
      --top-down             Also output a top-down video showing camera position + frustum
      --live                 Run as live desktop wallpaper (menu bar app)
      --config <path>        JSON config file (default: render_config.json)
      --help                 Show this help
    """)
}

// MARK: - Collect visible instances from ForestMap

func collectInstances(map: ForestMap, zMin: Float, zMax: Float) -> [InstanceData] {
    return map.instancesInRange(zMin: zMin, zMax: zMax).map { $0.toGPU() }
}

// MARK: - Save MTLTexture as PNG

func saveTexturePNG(_ texture: MTLTexture, path: String) {
    let w = texture.width, h = texture.height
    let bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
    texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                     from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1)),
                     mipmapLevel: 0)
    // BGRA → RGBA
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let b = pixels[i]; pixels[i] = pixels[i + 2]; pixels[i + 2] = b
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = ctx.makeImage() else {
        print("ERROR: Failed to create image for \(path)")
        return
    }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("ERROR: Cannot create image destination for \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil as CFDictionary?)
    CGImageDestinationFinalize(dest)
    print("Saved first frame: \(path)")
}

// MARK: - Debug: Top-down block visualization

func renderBlockTopDown(engine: WallpaperEngine,
                        zMin: Float, zMax: Float, outputPath: String) {
    let renderer = engine.renderer
    let map = engine.map
    let planner = engine.planner

    let regionZSize = zMax - zMin
    let regionXSize: Float = 14.0  // -7 to 7
    let centerX: Float = 0.0
    let centerZ = (zMin + zMax) / 2.0

    // Use the larger dimension for square viewport
    let viewSize = max(regionXSize, regionZSize) + 2.0  // margin
    let halfSize = viewSize / 2.0

    // Top-down camera — Y-up convention
    let eye = SIMD3<Float>(centerX, 500.0, centerZ)
    let up = SIMD3<Float>(0, 0, -1)
    let projMatrix = CameraState.orthographicMatrix(
        left: halfSize, right: -halfSize,
        bottom: halfSize, top: -halfSize,
        near: 1.0, far: 1000.0)

    let camera = CameraState(position: eye, forward: SIMD3(0, -1, 0), up: up)

    // Collect instances covering entire viewport (not just block range)
    let collectZMin = centerZ - halfSize - 2.0
    let collectZMax = centerZ + halfSize + 2.0
    let instances = collectInstances(map: map, zMin: collectZMin, zMax: collectZMax)

    guard let texture = renderer.render(camera: camera, projMatrix: projMatrix,
                                         forestInstances: instances,
                                         dayProgress: 0.5, gradientName: "solar noon") else {
        print("  ERROR: Failed to render top-down view")
        return
    }

    // Read texture into CGContext for overlay
    let imgW = renderer.width
    let imgH = renderer.height
    let bytesPerRow = imgW * 4
    var pixelData = [UInt8](repeating: 0, count: bytesPerRow * imgH)

    texture.getBytes(&pixelData, bytesPerRow: bytesPerRow,
                     from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: imgW, height: imgH, depth: 1)),
                     mipmapLevel: 0)

    // BGRA -> RGBA
    for i in stride(from: 0, to: pixelData.count, by: 4) {
        let b = pixelData[i]; pixelData[i] = pixelData[i + 2]; pixelData[i + 2] = b
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixelData, width: imgW, height: imgH,
                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("  ERROR: Cannot create CGContext")
        return
    }

    let pixelsPerUnit = Float(imgW) / viewSize
    let worldXMin = centerX - halfSize
    let worldZMin = centerZ - halfSize

    func toPixel(_ wx: Float, _ wz: Float) -> (CGFloat, CGFloat) {
        let px = CGFloat((wx - worldXMin) * pixelsPerUnit)
        let py = CGFloat((wz - worldZMin) * pixelsPerUnit)
        return (px, py)
    }

    // Draw minClearance circles (orange) + center dots (green)
    let minClear = planner.minClearance
    let clearR = CGFloat(minClear * pixelsPerUnit)
    ctx.setStrokeColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.7)
    ctx.setLineWidth(2.0)
    for inst in instances {
        if inst.x < worldXMin - minClear || inst.x > worldXMin + viewSize + minClear { continue }
        if inst.z < worldZMin - minClear || inst.z > worldZMin + viewSize + minClear { continue }
        let (px, py) = toPixel(inst.x, inst.z)
        ctx.strokeEllipse(in: CGRect(x: px - clearR, y: py - clearR,
                                      width: clearR * 2, height: clearR * 2))
        ctx.setFillColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: px - 3, y: py - 3, width: 6, height: 6))
        ctx.setStrokeColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.7)
    }

    // Draw block boundaries (dashed, bright cyan)
    ctx.setStrokeColor(red: 0.0, green: 1.0, blue: 1.0, alpha: 0.8)
    ctx.setLineWidth(2.0)
    ctx.setLineDash(phase: 0, lengths: [8, 4])
    var bz = floor(zMin / map.blockSize) * map.blockSize
    while bz <= zMax + map.blockSize {
        let (px0, py0) = toPixel(worldXMin, bz)
        let (px1, _) = toPixel(worldXMin + viewSize, bz)
        ctx.move(to: CGPoint(x: px0, y: py0))
        ctx.addLine(to: CGPoint(x: px1, y: py0))
        ctx.strokePath()
        bz += map.blockSize
    }
    ctx.setLineDash(phase: 0, lengths: [])

    // Draw camera path (red line)
    let pathPoints = planner.pathPoints
    if pathPoints.count >= 2 {
        ctx.setStrokeColor(red: 1.0, green: 0.2, blue: 0.1, alpha: 0.9)
        ctx.setLineWidth(3.0)
        ctx.beginPath()
        let (startPx, startPy) = toPixel(pathPoints[0].0, pathPoints[0].1)
        ctx.move(to: CGPoint(x: startPx, y: startPy))
        let step = max(1, pathPoints.count / 2000)
        for i in stride(from: step, to: pathPoints.count, by: step) {
            let (px, py) = toPixel(pathPoints[i].0, pathPoints[i].1)
            ctx.addLine(to: CGPoint(x: px, y: py))
        }
        let (endPx, endPy) = toPixel(pathPoints.last!.0, pathPoints.last!.1)
        ctx.addLine(to: CGPoint(x: endPx, y: endPy))
        ctx.strokePath()

        // Start (blue) and end (red) dots
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 1.0, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: startPx - 8, y: startPy - 8, width: 16, height: 16))
        ctx.setFillColor(red: 1.0, green: 0.2, blue: 0.1, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: endPx - 8, y: endPy - 8, width: 16, height: 16))
    }

    // Save
    guard let image = ctx.makeImage() else { print("  ERROR: Cannot create image"); return }
    let url = URL(fileURLWithPath: outputPath)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("  ERROR: Cannot create image destination"); return
    }
    CGImageDestinationAddImage(dest, image, nil as CFDictionary?)
    let _ = CGImageDestinationFinalize(dest)
    print("  Saved: \(outputPath)")
}

// MARK: - Debug Mode

func debugMode(engine: WallpaperEngine, config: Config, ec: EngineConfig) {
    print("=== Debug Mode: block top-down views ===")

    let debugDir = "\(ec.outputDir)/debug"
    try! FileManager.default.createDirectory(atPath: debugDir, withIntermediateDirectories: true)

    let blockSize = engine.map.blockSize

    // Block 0 top-down
    print("Rendering block_0.png...")
    renderBlockTopDown(engine: engine,
                       zMin: 0.0, zMax: blockSize,
                       outputPath: "\(debugDir)/block_0.png")

    // Block 0+1 top-down
    print("Rendering block_0_1.png...")
    renderBlockTopDown(engine: engine,
                       zMin: 0.0, zMax: blockSize * 2,
                       outputPath: "\(debugDir)/block_0_1.png")

    print("\nDone! Output: \(debugDir)/")
    print("  block_0.png   - first block top-down with path")
    print("  block_0_1.png - two blocks top-down")
}

// MARK: - Top-down video frame (CoreGraphics only, follows camera)

func renderTopDownVideoFrame(engine: WallpaperEngine, camX: Float, camZ: Float,
                              yaw: Float, fovDegrees: Float, size: Int = 1080) -> CGImage? {
    let map = engine.map
    let planner = engine.planner

    let viewSize: Float = 10.0  // 10x10 units visible
    let halfSize = viewSize / 2.0
    let pixelsPerUnit = Float(size) / viewSize

    // Center on camera with slight look-ahead
    let centerX = camX
    let centerZ = camZ + 1.0

    let worldXMin = centerX - halfSize
    let worldZMin = centerZ - halfSize

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = size * 4
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }

    // Dark background
    ctx.setFillColor(red: 0.05, green: 0.08, blue: 0.05, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // Coordinate transform: world → pixel (X right, Z up in image)
    func toPixel(_ wx: Float, _ wz: Float) -> (CGFloat, CGFloat) {
        let px = CGFloat((wx - worldXMin) * pixelsPerUnit)
        let py = CGFloat(Float(size)) - CGFloat((wz - worldZMin) * pixelsPerUnit)
        return (px, py)
    }

    let minClear = planner.minClearance
    let meshBaseRadius: Float = 0.36  // average forest mesh visual radius

    // Collect visible trees
    let collectZMin = centerZ - halfSize - 1.0
    let collectZMax = centerZ + halfSize + 1.0
    let allTrees = map.instancesInRange(zMin: collectZMin, zMax: collectZMax)

    // Draw mesh radius circles (red, dashed)
    let meshR = CGFloat(meshBaseRadius * pixelsPerUnit)
    ctx.setStrokeColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 0.4)
    ctx.setLineWidth(1.5)
    ctx.setLineDash(phase: 0, lengths: [4, 3])
    for tree in allTrees {
        let (px, py) = toPixel(tree.x, tree.z)
        if px < -meshR || px > CGFloat(size) + meshR { continue }
        if py < -meshR || py > CGFloat(size) + meshR { continue }
        ctx.strokeEllipse(in: CGRect(x: px - meshR, y: py - meshR, width: meshR * 2, height: meshR * 2))
    }
    ctx.setLineDash(phase: 0, lengths: [])

    // Draw minClearance circles (orange)
    let clearR = CGFloat(minClear * pixelsPerUnit)
    ctx.setStrokeColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.6)
    ctx.setLineWidth(2.0)
    for tree in allTrees {
        let (px, py) = toPixel(tree.x, tree.z)
        if px < -clearR || px > CGFloat(size) + clearR { continue }
        if py < -clearR || py > CGFloat(size) + clearR { continue }
        ctx.strokeEllipse(in: CGRect(x: px - clearR, y: py - clearR, width: clearR * 2, height: clearR * 2))
    }

    // Draw tree center dots (green)
    ctx.setFillColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 0.9)
    for tree in allTrees {
        let (px, py) = toPixel(tree.x, tree.z)
        if px < -5 || px > CGFloat(size) + 5 { continue }
        if py < -5 || py > CGFloat(size) + 5 { continue }
        ctx.fillEllipse(in: CGRect(x: px - 3, y: py - 3, width: 6, height: 6))
    }

    // Draw path (red line)
    let pathPoints = planner.pathPoints
    if pathPoints.count >= 2 {
        ctx.setStrokeColor(red: 1.0, green: 0.3, blue: 0.1, alpha: 0.9)
        ctx.setLineWidth(2.5)
        ctx.beginPath()
        var started = false
        for pt in pathPoints {
            let (px, py) = toPixel(pt.0, pt.1)
            if !started { ctx.move(to: CGPoint(x: px, y: py)); started = true }
            else { ctx.addLine(to: CGPoint(x: px, y: py)) }
        }
        ctx.strokePath()
    }

    // Draw view frustum (blue semi-transparent triangle)
    let fovRad = fovDegrees * .pi / 180.0
    let halfFov = fovRad / 2.0
    let frustumLen: Float = 4.0  // units forward

    let dirX = sin(yaw)
    let dirZ = cos(yaw)
    let leftAngle = yaw - halfFov
    let rightAngle = yaw + halfFov
    let leftX = camX + frustumLen * sin(leftAngle)
    let leftZ = camZ + frustumLen * cos(leftAngle)
    let rightX = camX + frustumLen * sin(rightAngle)
    let rightZ = camZ + frustumLen * cos(rightAngle)

    let (cpx, cpy) = toPixel(camX, camZ)
    let (lpx, lpy) = toPixel(leftX, leftZ)
    let (rpx, rpy) = toPixel(rightX, rightZ)

    ctx.setFillColor(red: 0.2, green: 0.4, blue: 1.0, alpha: 0.15)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: cpx, y: cpy))
    ctx.addLine(to: CGPoint(x: lpx, y: lpy))
    ctx.addLine(to: CGPoint(x: rpx, y: rpy))
    ctx.closePath()
    ctx.fillPath()

    ctx.setStrokeColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 0.6)
    ctx.setLineWidth(1.5)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: cpx, y: cpy))
    ctx.addLine(to: CGPoint(x: lpx, y: lpy))
    ctx.move(to: CGPoint(x: cpx, y: cpy))
    ctx.addLine(to: CGPoint(x: rpx, y: rpy))
    ctx.strokePath()

    // Draw camera dot (bright blue, large)
    ctx.setFillColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)
    ctx.fillEllipse(in: CGRect(x: cpx - 6, y: cpy - 6, width: 12, height: 12))

    // Draw forward direction line
    let fwdLen: Float = 1.0
    let (fwdPx, fwdPy) = toPixel(camX + fwdLen * dirX, camZ + fwdLen * dirZ)
    ctx.setStrokeColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 0.9)
    ctx.setLineWidth(2.0)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: cpx, y: cpy))
    ctx.addLine(to: CGPoint(x: fwdPx, y: fwdPy))
    ctx.strokePath()

    return ctx.makeImage()
}

// MARK: - CLI Export Mode

func main() async throws {
    let config = parseArgs()

    guard let device = MTLCreateSystemDefaultDevice() else {
        print("ERROR: Metal is not supported")
        exit(1)
    }

    // Load engine config
    var ec = loadEngineConfig(path: config.configPath)

    // CLI overrides
    if let w = config.width { ec.width = w }
    if let h = config.height { ec.height = h }
    if let f = config.fps { ec.fps = f }
    if let d = config.duration { ec.duration = d }

    // Day progression from --start-hour / --end-hour
    let startHour = config.startHour ?? ec.dayProgress * 24.0
    let endHour = config.endHour ?? startHour
    ec.dayProgress = startHour / 24.0
    if endHour != startHour {
        ec.dayProgressSpeed = (endHour - startHour) / 24.0 / ec.duration
    }

    let outputPath = config.outputPath ?? "\(ec.outputDir)/sequoia_wallpaper.mov"

    // Debug mode
    if config.debugStep > 0 {
        ec.width = 2048; ec.height = 2048
        print("Loading scene (\(ec.width)x\(ec.height))...")
        let engine = try WallpaperEngine(config: ec, device: device)
        print("Scene loaded.")
        debugMode(engine: engine, config: config, ec: ec)
        return
    }

    // Normal rendering mode (video export)
    print("Resolution: \(ec.width)x\(ec.height)")
    print("FPS: \(ec.fps), Duration: \(ec.duration)s")
    print("Output: \(outputPath)")

    let engine = try WallpaperEngine(config: ec, device: device)

    let exporter = VideoExporter(outputPath: outputPath,
                                  width: ec.width, height: ec.height, fps: ec.fps)
    try exporter.start()

    let totalFrames = Int(ec.duration * Float(ec.fps))
    let startTime = Date()

    for frame in 0..<totalFrames {
        guard let tex = engine.renderNextFrame() else { continue }
        try exporter.appendFrame(from: tex)

        if frame % (ec.fps * 2) == 0 || frame == totalFrames - 1 {
            let progress = Float(frame) / Float(totalFrames)
            let elapsed = Date().timeIntervalSince(startTime)
            let fps = Double(frame + 1) / max(0.001, elapsed)
            let eta = Double(totalFrames - frame - 1) / max(1, fps)
            print("  Frame \(frame + 1)/\(totalFrames) (\(Int(progress * 100))%) - \(String(format: "%.0f", fps)) fps - ETA: \(String(format: "%.0f", eta))s")
        }
    }

    try await exporter.finish()
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int64) ?? 0
    print("Done! \(outputPath) (\(String(format: "%.1f", Double(fileSize) / 1_048_576)) MB)")
}

// MARK: - Live Wallpaper App Mode

/// NSView backed by CAMetalLayer for rendering
class MetalLayerView: NSView {
    var metalLayer: CAMetalLayer!
    private let metalDevice: MTLDevice

    init(frame: NSRect, device: MTLDevice) {
        self.metalDevice = device
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        metalLayer = CAMetalLayer()
        metalLayer.device = metalDevice
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        return metalLayer
    }

    override func layout() {
        super.layout()
        metalLayer?.drawableSize = CGSize(
            width: bounds.width * metalLayer.contentsScale,
            height: bounds.height * metalLayer.contentsScale
        )
    }
}

/// Desktop-level window: above wallpaper, below icons
class WallpaperWindow: NSWindow {
    init(screen: NSScreen, device: MTLDevice) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        self.isOpaque = true
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.backgroundColor = .black

        let metalView = MetalLayerView(frame: screen.frame, device: device)
        self.contentView = metalView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// CVDisplayLink rendering loop
class DisplayLinkDriver {
    var engine: WallpaperEngine
    let metalLayer: CAMetalLayer
    let blitQueue: MTLCommandQueue
    var targetFPS: Int

    private var displayLink: CVDisplayLink?
    private var lastRenderTime: CFTimeInterval = 0
    private let renderQueue = DispatchQueue(label: "com.sequoia.render", qos: .userInteractive)

    // FPS tracking
    private var frameCount: Int = 0
    private var lastFPSTime: CFTimeInterval = 0
    private(set) var currentFPS: Int = 0

    // Freeze / ramp-up state
    private(set) var isFrozen: Bool = false
    private var savedTargetFPS: Int = 60
    private var rampStartTime: CFTimeInterval?
    private var rampDuration: CFTimeInterval = 0.5

    init(engine: WallpaperEngine, metalLayer: CAMetalLayer, targetFPS: Int) {
        self.engine = engine
        self.metalLayer = metalLayer
        self.blitQueue = engine.renderer.device.makeCommandQueue()!
        self.targetFPS = targetFPS
    }

    func start() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, context) -> CVReturn in
            let driver = Unmanaged<DisplayLinkDriver>.fromOpaque(context!).takeUnretainedValue()
            driver.tick()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }

    func stop() {
        if let link = displayLink { CVDisplayLinkStop(link) }
        displayLink = nil
    }

    func freeze() {
        guard !isFrozen else { return }
        isFrozen = true
        rampStartTime = nil
        engine.isPaused = true
        engine.speedMultiplier = 0.0
        savedTargetFPS = targetFPS
        engine.reset()
        renderQueue.sync { self.renderFrame() }
        targetFPS = 0
    }

    func unfreeze() {
        guard isFrozen else { return }
        isFrozen = false
        engine.isPaused = false
        engine.speedMultiplier = 0.0
        targetFPS = savedTargetFPS
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.rampStartTime = CACurrentMediaTime()
        }
    }

    /// Start a speed ramp-up without unfreezing (for resuming from Mission Control pause)
    func startRamp() {
        engine.speedMultiplier = 0.0
        rampStartTime = CACurrentMediaTime()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard targetFPS > 0 else { return }
        let interval = 1.0 / Double(targetFPS)
        guard now - lastRenderTime >= interval else { return }
        lastRenderTime = now

        // Update speed ramp
        if let start = rampStartTime {
            let t = min(1.0, Float((now - start) / rampDuration))
            engine.speedMultiplier = t
            if t >= 1.0 { rampStartTime = nil }
        }

        renderQueue.sync { self.renderFrame() }

        // Update FPS counter
        frameCount += 1
        if now - lastFPSTime >= 1.0 {
            currentFPS = frameCount
            frameCount = 0
            lastFPSTime = now
        }
    }

    private func renderFrame() {
        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let srcTexture = engine.renderNextFrame() else { return }
        guard let commandBuffer = blitQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        let srcW = srcTexture.width, srcH = srcTexture.height
        let dstW = drawable.texture.width, dstH = drawable.texture.height
        let copyW = min(srcW, dstW), copyH = min(srcH, dstH)

        blitEncoder.copy(
            from: srcTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
            to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Reusable slider view for menus
class MenuSliderView: NSView {
    let slider: NSSlider
    let label: NSTextField
    var onValueChanged: ((Float) -> Void)?
    let labelPrefix: String
    let labelFormat: String

    init(title: String, format: String = "%.1f", currentValue: Float, minValue: Float, maxValue: Float) {
        let width: CGFloat = 220, height: CGFloat = 50
        self.labelPrefix = title
        self.labelFormat = format
        label = NSTextField(labelWithString: "\(title): \(String(format: format, currentValue))")
        label.font = .menuFont(ofSize: 12)
        label.frame = CGRect(x: 16, y: 28, width: width - 32, height: 16)
        slider = NSSlider(value: Double(currentValue), minValue: Double(minValue), maxValue: Double(maxValue),
                          target: nil, action: nil)
        slider.frame = CGRect(x: 16, y: 4, width: width - 32, height: 22)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        addSubview(label)
        addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func sliderChanged(_ sender: NSSlider) {
        let val = Float(sender.doubleValue)
        label.stringValue = "\(labelPrefix): \(String(format: labelFormat, val))"
        onValueChanged?(val)
    }
}

/// Menu bar app delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var wallpaperWindow: WallpaperWindow!
    var engine: WallpaperEngine!
    var driver: DisplayLinkDriver!
    var engineConfig: EngineConfig!
    var speedSlider: MenuSliderView!
    var swaySlider: MenuSliderView!
    var swaySpeedSlider: MenuSliderView!
    var fpsMenuItems: [NSMenuItem] = []
    var fpsDisplayItem: NSMenuItem!
    var fpsTimer: Timer?
    var missionControlTimer: Timer?
    var missionControlActive: Bool = false
    var dockPID: Int32 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { print("ERROR: No screen"); NSApp.terminate(nil); return }
        guard let device = MTLCreateSystemDefaultDevice() else { print("ERROR: No Metal"); NSApp.terminate(nil); return }

        let scale = screen.backingScaleFactor
        let pw = Int(screen.frame.width * scale), ph = Int(screen.frame.height * scale)
        print("Screen: \(pw)x\(ph) @ \(scale)x")

        // Load config, override resolution to screen native
        let configPath: String
        if let bp = Bundle.main.path(forResource: "render_config", ofType: "json") { configPath = bp }
        else { configPath = "render_config.json" }
        engineConfig = loadEngineConfig(path: configPath)
        engineConfig.width = pw
        engineConfig.height = ph
        engineConfig.fps = 60

        do { engine = try WallpaperEngine(config: engineConfig, device: device) }
        catch { print("ERROR: \(error)"); NSApp.terminate(nil); return }

        // In live mode, clear fixed gradient so timeMode (light/dark/realTime) controls lighting
        engine.gradientName = nil

        // Save first frame as PNG next to the .app bundle (project root)
        // Use renderCurrentState() to avoid advancing state, so the PNG matches
        // the frozen frame (both at distance=0)
        if let firstFrame = engine.renderCurrentState() {
            let bundlePath = Bundle.main.bundlePath as NSString
            let rootDir = bundlePath.deletingLastPathComponent
            let savePath = (rootDir as NSString).appendingPathComponent("first_frame.png")
            saveTexturePNG(firstFrame, path: savePath)
        }

        wallpaperWindow = WallpaperWindow(screen: screen, device: device)
        wallpaperWindow.orderFront(nil)

        let metalView = wallpaperWindow.contentView as! MetalLayerView

        // Start engine paused so the display link won't advance state before
        // we decide whether to freeze or animate.
        engine.isPaused = true
        driver = DisplayLinkDriver(engine: engine, metalLayer: metalView.metalLayer!, targetFPS: engineConfig.fps)
        driver.start()

        setupMenuBar()

        // Update FPS display in menu every second
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.fpsDisplayItem.title = "FPS: \(self.driver.currentFPS)"
        }

        // Detect desktop visibility via occlusion (full-screen apps)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: wallpaperWindow)

        // Poll CGWindowList to detect Mission Control (Dock creates overlay windows)
        missionControlTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollMissionControl()
        }

        // Initial state based on wallpaper window visibility
        if wallpaperWindow.occlusionState.contains(.visible) {
            engine.isPaused = false
        } else {
            driver.freeze()
        }

        print("Live wallpaper started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        fpsTimer?.invalidate()
        missionControlTimer?.invalidate()
        driver?.stop()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tree.fill", accessibilityDescription: "Sequoia Wallpaper")
        }

        let menu = NSMenu()
        fpsDisplayItem = NSMenuItem(title: "FPS: 0", action: nil, keyEquivalent: "")
        fpsDisplayItem.isEnabled = false
        menu.addItem(fpsDisplayItem)
        menu.addItem(.separator())

        // Speed slider
        let speedItem = NSMenuItem()
        speedSlider = MenuSliderView(title: "Speed", format: "%.1f%%", currentValue: engine.speedPercent, minValue: 0.1, maxValue: 10.0)
        speedSlider.onValueChanged = { [weak self] v in self?.engine.speedPercent = v }
        speedItem.view = speedSlider
        menu.addItem(speedItem)

        // Sway amplitude slider
        let swayItem = NSMenuItem()
        swaySlider = MenuSliderView(title: "Sway", format: "%.1f°", currentValue: engine.swayAmplitude, minValue: 0, maxValue: 15.0)
        swaySlider.onValueChanged = { [weak self] v in self?.engine.swayAmplitude = v }
        swayItem.view = swaySlider
        menu.addItem(swayItem)

        // Sway speed slider
        let swaySpeedItem = NSMenuItem()
        swaySpeedSlider = MenuSliderView(title: "Sway Speed", format: "%.1f", currentValue: engine.swaySpeed, minValue: 0.1, maxValue: 5.0)
        swaySpeedSlider.onValueChanged = { [weak self] v in self?.engine.swaySpeed = v }
        swaySpeedItem.view = swaySpeedSlider
        menu.addItem(swaySpeedItem)

        menu.addItem(.separator())

        // FPS submenu
        let fpsItem = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for fps in [30, 60] {
            let item = NSMenuItem(title: "\(fps) FPS", action: #selector(setFPS(_:)), keyEquivalent: "")
            item.target = self; item.tag = fps
            if fps == engine.fps { item.state = .on }
            fpsMenu.addItem(item); fpsMenuItems.append(item)
        }
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Save Desktop Image", action: #selector(saveDesktopImage), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.shared.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func setFPS(_ sender: NSMenuItem) {
        engine.fps = sender.tag; driver.targetFPS = sender.tag
        for item in fpsMenuItems { item.state = item.tag == sender.tag ? .on : .off }
    }

    @objc private func saveDesktopImage() {
        guard let texture = engine.renderCurrentState() else { return }
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let savePath = desktopURL.appendingPathComponent("AwakeSequoia.png").path
        saveTexturePNG(texture, path: savePath)
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        let visible = wallpaperWindow.occlusionState.contains(.visible)
        if visible {
            if missionControlActive {
                driver.unfreeze()
                engine.isPaused = true
            } else {
                driver.unfreeze()
            }
        } else {
            driver.freeze()
        }
    }

    /// Detect Mission Control by checking if Dock (com.apple.dock) has windows at layer >= 0
    private func pollMissionControl() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }

        // Find Dock PID (cached after first lookup)
        if dockPID == 0 {
            if let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                dockPID = dockApp.processIdentifier
            }
        }
        guard dockPID != 0 else { return }

        // Check if Dock has any window at layer >= 0 (Mission Control overlay windows)
        var hasMCWindow = false
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == dockPID else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer >= 0 {
                hasMCWindow = true
                break
            }
        }

        if hasMCWindow != missionControlActive {
            missionControlActive = hasMCWindow
            let visible = wallpaperWindow.occlusionState.contains(.visible)
            let frozen = driver.isFrozen
            if missionControlActive {
                // Only pause if wallpaper was frozen (user wasn't on desktop)
                // If already playing (user on desktop), let it continue
                if frozen || engine.isPaused {
                    engine.isPaused = true
                }
            } else if visible && !frozen {
                // MC exited, wallpaper visible → resume only if was paused
                if engine.isPaused {
                    engine.isPaused = false
                    driver.startRamp()
                }
            }
        }
    }

}

// MARK: - Entry Point

let cliConfig = parseArgs()

// Default to live mode when launched from .app bundle (double-click, no CLI args)
let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
let hasExplicitArgs = CommandLine.arguments.count > 1

if cliConfig.liveMode || (isAppBundle && !hasExplicitArgs) {
    // Live wallpaper mode
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
} else {
    // CLI mode (video export / debug)
    Task {
        do {
            try await main()
            exit(0)
        } catch {
            print("ERROR: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}
