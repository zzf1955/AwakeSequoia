import Foundation
import Metal
import MetalKit
import simd

/// Uniforms matching Apple's shader layout (128 bytes, buffer index 0)
struct Uniforms {
    var viewTransform: float4x4
    var projectionTransform: float4x4
}

/// Per-instance data matching Apple's shader layout (16 bytes, buffer index 2)
struct InstanceData {
    var x: Float
    var z: Float
    var rotation: Float
    var scaleRadial: UInt16
    var scaleVertical: UInt16
}

/// Convert Float to Float16 stored as UInt16
func floatToHalf(_ value: Float) -> UInt16 {
    var f = value
    var h: UInt16 = 0
    withUnsafePointer(to: &f) { fPtr in
        withUnsafeMutablePointer(to: &h) { hPtr in
            let bits = fPtr.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            let sign = (bits >> 31) & 1
            let exp = Int((bits >> 23) & 0xFF) - 127
            let mantissa = bits & 0x7FFFFF

            if exp > 15 {
                hPtr.pointee = UInt16(sign << 15) | 0x7C00
            } else if exp < -14 {
                hPtr.pointee = UInt16(sign << 15)
            } else {
                let hExp = UInt16(exp + 15)
                let hMantissa = UInt16(mantissa >> 13)
                hPtr.pointee = UInt16(sign << 15) | (hExp << 10) | hMantissa
            }
        }
    }
    return h
}

/// Simple seeded RNG for reproducible tree placement
struct SeededRNG {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextFloat() -> Float {
        return Float(next() >> 33) / Float(1 << 31)
    }
}

/// Pure rendering layer — accepts instance data + camera state, renders frames.
/// Does NOT know about ForestMap, PathPlanner, or world layout.
class ForestRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var drawPipeline: MTLRenderPipelineState!
    var backgroundPipeline: MTLRenderPipelineState!

    var forestMesh: MTKMesh!
    var gradientTextures: [MTLTexture] = []

    // MSAA 4x
    var msaaColorTexture: MTLTexture!
    var msaaDepthTexture: MTLTexture!
    var resolvedColorTexture: MTLTexture!
    let sampleCount = 4

    let width: Int
    let height: Int

    var depthStencilState: MTLDepthStencilState!

    /// Fragment parameters
    var dimmingGradientAmount: Float = 0.0
    var gradientUVOffset: Float = 0.0
    var gradientUVScale: Float = 1.0
    var gradientWashout: Float = 0.0

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.device = device
        self.width = width
        self.height = height

        guard let queue = device.makeCommandQueue() else {
            throw RendererError.initFailed("Failed to create command queue")
        }
        self.commandQueue = queue

        try setupPipelines()
        try loadScene()
        setupRenderTargets()
        setupDepthStencil()
    }

    private func setupPipelines() throws {
        let libURL = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperSequoiaExtension.appex/Contents/Resources/default.metallib")
        let library = try device.makeLibrary(URL: libURL)

        let constantValues = MTLFunctionConstantValues()
        var useSecondGradient = true
        constantValues.setConstantValue(&useSecondGradient, type: .bool, index: 0)

        let drawVertex = try library.makeFunction(name: "drawVertex", constantValues: constantValues)
        let drawFragment = try library.makeFunction(name: "drawFragment", constantValues: constantValues)
        let bgVertex = try library.makeFunction(name: "screenTriangleVertex", constantValues: constantValues)
        let bgFragment = try library.makeFunction(name: "backgroundFragment", constantValues: constantValues)

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 1
        vertexDescriptor.attributes[1].format = .half2
        vertexDescriptor.attributes[1].offset = 12
        vertexDescriptor.attributes[1].bufferIndex = 1
        vertexDescriptor.layouts[1].stride = 16

        let drawDesc = MTLRenderPipelineDescriptor()
        drawDesc.vertexFunction = drawVertex
        drawDesc.fragmentFunction = drawFragment
        drawDesc.vertexDescriptor = vertexDescriptor
        drawDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        drawDesc.colorAttachments[0].isBlendingEnabled = true
        drawDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        drawDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        drawDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        drawDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        drawDesc.depthAttachmentPixelFormat = .depth32Float
        drawDesc.rasterSampleCount = sampleCount
        drawPipeline = try device.makeRenderPipelineState(descriptor: drawDesc)

        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = bgVertex
        bgDesc.fragmentFunction = bgFragment
        bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        bgDesc.depthAttachmentPixelFormat = .depth32Float
        bgDesc.rasterSampleCount = sampleCount
        backgroundPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
    }

    private func loadScene() throws {
        let scene = try SceneLoader.load(device: device)
        forestMesh = scene.forestMesh
        gradientTextures = scene.gradientTextures

        printMeshBounds(forestMesh, name: "forest")
    }

    private func printMeshBounds(_ mesh: MTKMesh, name: String) {
        let vb = mesh.vertexBuffers[0]
        let stride = 16
        let vertexCount = mesh.vertexCount
        let ptr = vb.buffer.contents().advanced(by: vb.offset)

        var minX: Float = .infinity, maxX: Float = -.infinity
        var minY: Float = .infinity, maxY: Float = -.infinity
        var minZ: Float = .infinity, maxZ: Float = -.infinity

        for i in 0..<vertexCount {
            let vertexPtr = ptr.advanced(by: i * stride)
            let x = vertexPtr.load(as: Float.self)
            let y = vertexPtr.advanced(by: 4).load(as: Float.self)
            let z = vertexPtr.advanced(by: 8).load(as: Float.self)
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
            if z < minZ { minZ = z }; if z > maxZ { maxZ = z }
        }

        print("  Mesh '\(name)': \(vertexCount) vertices, stride=\(stride)")
        print("    X: [\(String(format: "%.3f", minX)), \(String(format: "%.3f", maxX))]")
        print("    Y: [\(String(format: "%.3f", minY)), \(String(format: "%.3f", maxY))]")
        print("    Z: [\(String(format: "%.3f", minZ)), \(String(format: "%.3f", maxZ))]")
        print("    Center XY: (\(String(format: "%.3f", (minX+maxX)/2)), \(String(format: "%.3f", (minY+maxY)/2)))")
    }

    private func setupRenderTargets() {
        let msaaColorDesc = MTLTextureDescriptor()
        msaaColorDesc.textureType = .type2DMultisample
        msaaColorDesc.pixelFormat = .bgra8Unorm_srgb
        msaaColorDesc.width = width
        msaaColorDesc.height = height
        msaaColorDesc.sampleCount = sampleCount
        msaaColorDesc.usage = .renderTarget
        msaaColorDesc.storageMode = .private
        msaaColorTexture = device.makeTexture(descriptor: msaaColorDesc)

        let msaaDepthDesc = MTLTextureDescriptor()
        msaaDepthDesc.textureType = .type2DMultisample
        msaaDepthDesc.pixelFormat = .depth32Float
        msaaDepthDesc.width = width
        msaaDepthDesc.height = height
        msaaDepthDesc.sampleCount = sampleCount
        msaaDepthDesc.usage = .renderTarget
        msaaDepthDesc.storageMode = .private
        msaaDepthTexture = device.makeTexture(descriptor: msaaDepthDesc)

        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        resolveDesc.usage = [.renderTarget, .shaderRead]
        resolveDesc.storageMode = .managed
        resolvedColorTexture = device.makeTexture(descriptor: resolveDesc)
    }

    private func setupDepthStencil() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .less
        desc.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: desc)
    }

    /// Gradient name to index mapping
    static let gradientNames: [String: Int] = [
        "solar midnight": 0, "midnight": 0,
        "dawn": 1,
        "sunrise": 2,
        "mid morning": 3,
        "solar noon": 4, "noon": 4,
        "late afternoon": 5,
        "sunset": 6,
        "dusk": 7,
    ]

    /// Render a frame with external instance data and camera state
    func render(camera: CameraState, projMatrix: float4x4,
                forestInstances: [InstanceData],
                dayProgress: Float = 0.5, gradientName: String? = nil) -> MTLTexture? {

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        var uniforms = Uniforms(viewTransform: camera.viewMatrix, projectionTransform: projMatrix)

        let gradA: MTLTexture, gradB: MTLTexture
        var gradientMix: Float
        var dimming = dimmingGradientAmount

        let rawA: MTLTexture, rawB: MTLTexture
        if let name = gradientName, name != "auto",
           let idx = ForestRenderer.gradientNames[name.lowercased()] {
            rawA = gradientTextures[idx]; rawB = gradientTextures[idx]; gradientMix = 0.0
        } else {
            let lighting = SolarPosition.lighting(forDayProgress: dayProgress)
            rawA = gradientTextures[lighting.gradientIndexA]
            rawB = gradientTextures[lighting.gradientIndexB]
            gradientMix = lighting.mix
        }

        let needsRemap = gradientUVOffset != 0.0 || gradientUVScale != 1.0 || gradientWashout != 0.0
        gradA = needsRemap ? remapGradientTexture(rawA) : rawA
        gradB = needsRemap ? (rawB === rawA ? gradA : remapGradientTexture(rawB)) : rawB

        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = msaaColorTexture
        renderPassDesc.colorAttachments[0].resolveTexture = resolvedColorTexture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .multisampleResolve
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDesc.depthAttachment.texture = msaaDepthTexture
        renderPassDesc.depthAttachment.loadAction = .clear
        renderPassDesc.depthAttachment.storeAction = .dontCare
        renderPassDesc.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return nil }

        // Background
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentTexture(gradA, index: 0)
        encoder.setFragmentTexture(gradB, index: 1)
        encoder.setFragmentBytes(&gradientMix, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&dimming, length: MemoryLayout<Float>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Forest trees
        if !forestInstances.isEmpty {
            encoder.setRenderPipelineState(drawPipeline)
            encoder.setDepthStencilState(depthStencilState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
            let forestBuf = device.makeBuffer(bytes: forestInstances,
                                               length: MemoryLayout<InstanceData>.stride * forestInstances.count,
                                               options: .storageModeShared)!
            encoder.setVertexBuffer(forestBuf, offset: 0, index: 2)
            encoder.setFragmentTexture(gradA, index: 0)
            encoder.setFragmentTexture(gradB, index: 1)
            encoder.setFragmentBytes(&gradientMix, length: MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&dimming, length: MemoryLayout<Float>.size, index: 1)
            drawMeshInstanced(forestMesh, encoder: encoder, instanceCount: forestInstances.count)
        }

        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: resolvedColorTexture!)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return resolvedColorTexture
    }

    /// Render specific meshes with given instances (for debug visualization)
    func renderMeshes(_ meshes: [MTKMesh], instances: [InstanceData],
                      viewMatrix: float4x4, projMatrix: float4x4,
                      dayProgress: Float = 0.5, gradientName: String? = nil) -> MTLTexture? {

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        guard let tmpBuffer = device.makeBuffer(
            bytes: instances,
            length: MemoryLayout<InstanceData>.stride * instances.count,
            options: .storageModeShared) else { return nil }

        var uniforms = Uniforms(viewTransform: viewMatrix, projectionTransform: projMatrix)

        let gradA: MTLTexture, gradB: MTLTexture
        var gradientMix: Float = 0.0
        var dimming = dimmingGradientAmount

        if let name = gradientName, let idx = ForestRenderer.gradientNames[name.lowercased()] {
            gradA = gradientTextures[idx]; gradB = gradA
        } else {
            let lighting = SolarPosition.lighting(forDayProgress: dayProgress)
            gradA = gradientTextures[lighting.gradientIndexA]
            gradB = gradientTextures[lighting.gradientIndexB]
            gradientMix = lighting.mix
        }

        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = msaaColorTexture
        renderPassDesc.colorAttachments[0].resolveTexture = resolvedColorTexture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .multisampleResolve
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDesc.depthAttachment.texture = msaaDepthTexture
        renderPassDesc.depthAttachment.loadAction = .clear
        renderPassDesc.depthAttachment.storeAction = .dontCare
        renderPassDesc.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return nil }

        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentTexture(gradA, index: 0)
        encoder.setFragmentTexture(gradB, index: 1)
        encoder.setFragmentBytes(&gradientMix, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&dimming, length: MemoryLayout<Float>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(drawPipeline)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.setVertexBuffer(tmpBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(gradA, index: 0)
        encoder.setFragmentTexture(gradB, index: 1)
        encoder.setFragmentBytes(&gradientMix, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&dimming, length: MemoryLayout<Float>.size, index: 1)
        for mesh in meshes { drawMeshInstanced(mesh, encoder: encoder, instanceCount: instances.count) }

        encoder.endEncoding()
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: resolvedColorTexture!)
            blitEncoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return resolvedColorTexture
    }

    // MARK: - Gradient remapping

    private var remapCache: [ObjectIdentifier: MTLTexture] = [:]
    private var remapCacheKey: (Float, Float, Float) = (0, 1, 0)

    private func remapGradientTexture(_ source: MTLTexture) -> MTLTexture {
        let key = (gradientUVOffset, gradientUVScale, gradientWashout)
        if key != remapCacheKey {
            remapCache.removeAll()
            remapCacheKey = key
        }

        let sourceId = ObjectIdentifier(source)
        if let cached = remapCache[sourceId] { return cached }

        let w = source.width
        let bpp = 16
        let bpr = w * bpp

        var srcData = [Float](repeating: 0, count: w * 4)
        srcData.withUnsafeMutableBufferPointer { buf in
            source.getBytes(buf.baseAddress!, bytesPerRow: bpr,
                           from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: 1, depth: 1)),
                           mipmapLevel: 0)
        }

        var dstData = [Float](repeating: 0, count: w * 4)
        for i in 0..<w {
            let u = Float(i) / Float(w - 1)
            let srcU = min(max(u * gradientUVScale + gradientUVOffset, 0), 1)
            let srcIdx = srcU * Float(w - 1)
            let idx0 = min(Int(srcIdx), w - 1)
            let idx1 = min(idx0 + 1, w - 1)
            let frac = srcIdx - Float(idx0)
            for c in 0..<4 {
                dstData[i * 4 + c] = srcData[idx0 * 4 + c] * (1 - frac) + srcData[idx1 * 4 + c] * frac
            }
        }

        if gradientWashout > 0 {
            let wo = gradientWashout
            for i in 0..<(w * 4) {
                dstData[i] = dstData[i] * (1 - wo) + 1.0 * wo
            }
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type2D
        desc.pixelFormat = source.pixelFormat
        desc.width = w
        desc.height = 1
        desc.usage = .shaderRead
        desc.storageMode = .managed

        let newTex = device.makeTexture(descriptor: desc)!
        dstData.withUnsafeBufferPointer { buf in
            newTex.replace(region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: 1, depth: 1)),
                          mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: bpr)
        }

        remapCache[sourceId] = newTex
        return newTex
    }

    private func drawMeshInstanced(_ mesh: MTKMesh, encoder: MTLRenderCommandEncoder, instanceCount: Int) {
        for vertexBuffer in mesh.vertexBuffers {
            encoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 1)
        }
        for submesh in mesh.submeshes {
            encoder.drawIndexedPrimitives(
                type: submesh.primitiveType,
                indexCount: submesh.indexCount,
                indexType: submesh.indexType,
                indexBuffer: submesh.indexBuffer.buffer,
                indexBufferOffset: submesh.indexBuffer.offset,
                instanceCount: instanceCount
            )
        }
    }

    /// Save texture to PNG file
    func saveTextureToPNG(_ texture: MTLTexture, path: String) {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        var pixelData = [UInt8](repeating: 0, count: byteCount)

        texture.getBytes(&pixelData, bytesPerRow: bytesPerRow,
                        from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
                        mipmapLevel: 0)

        // BGRA -> RGBA
        for i in stride(from: 0, to: byteCount, by: 4) {
            let b = pixelData[i]
            pixelData[i] = pixelData[i + 2]
            pixelData[i + 2] = b
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: &pixelData, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            print("ERROR: Failed to create CGImage")
            return
        }

        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
            print("ERROR: Failed to create image destination")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("  Saved: \(path)")
    }

    enum RendererError: Error, CustomStringConvertible {
        case initFailed(String)
        var description: String { return "Renderer error: \(self)" }
    }
}
