import Foundation
import Metal
import MetalKit
import ModelIO

/// Loads Sequoia wallpaper assets from the system extension bundle
struct SceneLoader {

    static let assetsPath = "/System/Library/ExtensionKit/Extensions/WallpaperSequoiaExtension.appex/Contents/Resources"

    /// EXR gradient texture names in time-of-day order
    static let gradientNames = [
        "solar midnight",
        "dawn",
        "sunrise",
        "mid morning",
        "solar noon",
        "late afternoon",
        "sunset",
        "dusk"
    ]

    struct LoadedScene {
        let forestMesh: MTKMesh
        let gradientTextures: [MTLTexture]  // 8 EXR textures
        let cameraPathPoints: [[SIMD3<Float>]]  // 4 bezier paths, each with control points
    }

    static func load(device: MTLDevice) throws -> LoadedScene {
        let allocator = MTKMeshBufferAllocator(device: device)

        // Load meshes
        let forestMesh = try loadMesh(named: "mesh.usdc", device: device, allocator: allocator)

        // Load EXR gradient textures
        let gradients = try loadGradientTextures(device: device)

        // Load camera paths
        let paths = try loadCameraPaths()

        return LoadedScene(
            forestMesh: forestMesh,
            gradientTextures: gradients,
            cameraPathPoints: paths
        )
    }

    private static func loadMesh(named filename: String, device: MTLDevice,
                                  allocator: MTKMeshBufferAllocator) throws -> MTKMesh {
        let url = URL(fileURLWithPath: "\(assetsPath)/\(filename)")

        let vertexDescriptor = MDLVertexDescriptor()
        // Position: packed_float3 (12 bytes) — Apple uses buffer index 1, but MDL loads into index 0
        let posAttr = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                          format: .float3,
                                          offset: 0,
                                          bufferIndex: 0)
        vertexDescriptor.attributes[0] = posAttr

        // UV: half2 (4 bytes) at offset 12 — matches Apple's packed_float3 + half2 = 16 stride
        let uvAttr = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate,
                                         format: .half2,
                                         offset: 12,
                                         bufferIndex: 0)
        vertexDescriptor.attributes[1] = uvAttr

        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: 16) // packed_float3(12) + half2(4)

        let asset = MDLAsset(url: url,
                             vertexDescriptor: vertexDescriptor,
                             bufferAllocator: allocator)

        guard let mdlMesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else {
            throw LoadError.meshNotFound(filename)
        }

        return try MTKMesh(mesh: mdlMesh, device: device)
    }

    private static func loadGradientTextures(device: MTLDevice) throws -> [MTLTexture] {
        let loader = MTKTextureLoader(device: device)
        var textures: [MTLTexture] = []

        for name in gradientNames {
            let url = URL(fileURLWithPath: "\(assetsPath)/\(name).exr")
            let options: [MTKTextureLoader.Option: Any] = [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .SRGB: false  // EXR is linear HDR
            ]
            let texture = try loader.newTexture(URL: url, options: options)
            textures.append(texture)
        }

        return textures
    }

    private static func loadCameraPaths() throws -> [[SIMD3<Float>]] {
        // Hardcoded from paths.usdc analysis (4 cubic bezier paths)
        // Each path: control points in XY plane, Z=0, Y goes 0→20
        let path1: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 1.3087697, 0), SIMD3(0, 2, 0),
            SIMD3(0, 2.318355, 0), SIMD3(0.26870778, 2.9379332, 0), SIMD3(0.2925589, 3.4436047, 0),
            SIMD3(0.32458138, 4.1225185, 0), SIMD3(0.07333587, 4.39386, 0), SIMD3(-0.02989116, 5.020473, 0),
            SIMD3(-0.15150452, 5.7586956, 0), SIMD3(-1.3371172, 6.382932, 0), SIMD3(-0.79872084, 7.429851, 0),
            SIMD3(-0.35114613, 8.300166, 0), SIMD3(-0.080665015, 8.702691, 0), SIMD3(0.03731104, 9.142761, 0),
            SIMD3(0.20737255, 9.777119, 0), SIMD3(0.60766476, 10.859436, 0), SIMD3(0.6058854, 11.6277685, 0),
            SIMD3(0.6040545, 12.418327, 0), SIMD3(1.3089075, 12.995235, 0), SIMD3(0.98128575, 13.462468, 0),
            SIMD3(0.3963561, 14.296657, 0), SIMD3(1.0838459, 14.585375, 0), SIMD3(0.49134442, 15.163915, 0),
            SIMD3(-0.029891938, 15.672869, 0), SIMD3(-0.62190336, 16.361814, 0), SIMD3(-0.45554933, 17.117306, 0),
            SIMD3(-0.32140017, 17.72654, 0), SIMD3(-0.035395846, 18.006437, 0), SIMD3(0.21323313, 18.550095, 0),
            SIMD3(0.3513929, 18.852198, 0), SIMD3(0, 19.340235, 0), SIMD3(0, 20, 0)
        ]

        let path2: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 1.3087695, 0), SIMD3(0, 2, 0),
            SIMD3(0, 2.203756, 0), SIMD3(0.10619108, 2.6314483, 0), SIMD3(-0.00058588444, 2.8702645, 0),
            SIMD3(-0.078333445, 3.044154, 0), SIMD3(-0.27472207, 3.0689476, 0), SIMD3(-0.37409404, 3.2159557, 0),
            SIMD3(-0.4666716, 3.3529124, 0), SIMD3(-0.51018924, 3.5484965, 0), SIMD3(-0.48597777, 3.9311743, 0),
            SIMD3(-0.45330057, 4.4476585, 0), SIMD3(-1.1087501, 5.123031, 0), SIMD3(-1.3817908, 5.5849986, 0),
            SIMD3(-1.526593, 5.8299947, 0), SIMD3(-1.6524398, 5.9973063, 0), SIMD3(-1.7587576, 6.3149557, 0),
            SIMD3(-1.8492818, 6.585418, 0), SIMD3(-2.2188826, 6.7871943, 0), SIMD3(-2.1967788, 7.0965743, 0),
            SIMD3(-2.1779308, 7.360382, 0), SIMD3(-2.0064201, 7.753954, 0), SIMD3(-2.2012484, 8.027321, 0),
            SIMD3(-2.5040748, 8.452222, 0), SIMD3(-2.3691711, 8.814321, 0), SIMD3(-2.4057002, 9.382049, 0),
            SIMD3(-2.4554121, 10.154663, 0), SIMD3(-1.943603, 10.368449, 0), SIMD3(-1.9352627, 11.230865, 0),
            SIMD3(-1.9283935, 11.941155, 0), SIMD3(-1.4253278, 12.571173, 0), SIMD3(-1.4626515, 13.201962, 0),
            SIMD3(-1.4778479, 13.45879, 0), SIMD3(-1.6609904, 13.6330185, 0), SIMD3(-1.744956, 13.835609, 0),
            SIMD3(-1.8318893, 14.045361, 0), SIMD3(-1.8906381, 14.259841, 0), SIMD3(-1.9015244, 14.774132, 0),
            SIMD3(-1.9095048, 15.151139, 0), SIMD3(-1.8547599, 15.687646, 0), SIMD3(-2.076962, 16.182678, 0),
            SIMD3(-2.2944677, 16.667248, 0), SIMD3(-2.4417636, 17.176691, 0), SIMD3(-2.3885267, 17.542105, 0),
            SIMD3(-2.3136904, 18.055775, 0), SIMD3(-1.5648174, 18.339209, 0), SIMD3(-1.1892594, 18.599821, 0),
            SIMD3(-0.9073489, 18.795448, 0), SIMD3(0, 19.340235, 0), SIMD3(0, 20, 0)
        ]

        let path3: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 1.4315679, 0), SIMD3(0, 2, 0),
            SIMD3(0, 2.4747882, 0), SIMD3(0.6155964, 3.1302137, 0), SIMD3(0.9940342, 3.5669863, 0),
            SIMD3(1.4009401, 4.0366154, 0), SIMD3(1.7398916, 4.653736, 0), SIMD3(1.9119253, 5.4484572, 0),
            SIMD3(2.07175, 6.186778, 0), SIMD3(1.7638409, 6.526955, 0), SIMD3(1.7113608, 7.3339205, 0),
            SIMD3(1.6431856, 8.382223, 0), SIMD3(0.96556306, 8.556697, 0), SIMD3(1.3801694, 9.755207, 0),
            SIMD3(1.5924293, 10.368791, 0), SIMD3(1.8404388, 11.005491, 0), SIMD3(1.7601073, 11.632254, 0),
            SIMD3(1.6639625, 12.382394, 0), SIMD3(1.4764973, 13.354192, 0), SIMD3(1.6023513, 14.173102, 0),
            SIMD3(1.7128041, 14.8918, 0), SIMD3(2.0771263, 15.334647, 0), SIMD3(2.0333636, 16.110098, 0),
            SIMD3(1.9941304, 16.805288, 0), SIMD3(1.0487783, 16.739897, 0), SIMD3(0.8774458, 17.954004, 0),
            SIMD3(0.78032243, 18.642246, 0), SIMD3(0, 19.428957, 0), SIMD3(0, 20, 0)
        ]

        let path4: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 1.1727681, 0), SIMD3(0, 2, 0),
            SIMD3(0, 2.6909533, 0), SIMD3(0.31718194, 2.8288324, 0), SIMD3(0.34124056, 3.475784, 0),
            SIMD3(0.36529842, 4.1227155, 0), SIMD3(1.006421, 3.9864647, 0), SIMD3(1.1121418, 4.821964, 0),
            SIMD3(1.181284, 5.3683853, 0), SIMD3(1.5215137, 6.041043, 0), SIMD3(1.907594, 6.4961553, 0),
            SIMD3(2.1795268, 6.8167105, 0), SIMD3(3.0180645, 7.2254367, 0), SIMD3(3.217934, 7.7129755, 0),
            SIMD3(3.6767669, 8.832201, 0), SIMD3(2.6118736, 9.343973, 0), SIMD3(2.6248465, 10.14316, 0),
            SIMD3(2.6353843, 10.7923355, 0), SIMD3(2.9363167, 11.677888, 0), SIMD3(2.7017875, 12.264642, 0),
            SIMD3(2.4444962, 12.908342, 0), SIMD3(2.566804, 13.136097, 0), SIMD3(2.6479442, 13.960642, 0),
            SIMD3(2.7226229, 14.719524, 0), SIMD3(2.030921, 14.956562, 0), SIMD3(2.0624595, 15.807839, 0),
            SIMD3(2.08571, 16.435413, 0), SIMD3(2.0929713, 16.96534, 0), SIMD3(1.8836617, 18.008781, 0),
            SIMD3(1.5856245, 19.494545, 0), SIMD3(0, 19.563253, 0), SIMD3(0, 20, 0)
        ]

        return [path1, path2, path3, path4]
    }

    enum LoadError: Error, CustomStringConvertible {
        case meshNotFound(String)
        case textureLoadFailed(String)

        var description: String {
            switch self {
            case .meshNotFound(let name): return "Mesh not found in \(name)"
            case .textureLoadFailed(let name): return "Failed to load texture: \(name)"
            }
        }
    }
}
