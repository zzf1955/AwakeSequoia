import Foundation
import AVFoundation
import CoreVideo
import Metal
import VideoToolbox

/// Exports rendered frames to a video file
class VideoExporter {
    let outputURL: URL
    let width: Int
    let height: Int
    let fps: Int

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameCount: Int = 0

    init(outputPath: String, width: Int, height: Int, fps: Int = 30) {
        self.outputURL = URL(fileURLWithPath: outputPath)
        self.width = width
        self.height = height
        self.fps = fps
    }

    func start() throws {
        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)

        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,  // ~4 bpp
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput!.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput!,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes)

        assetWriter!.add(videoInput!)
        assetWriter!.startWriting()
        assetWriter!.startSession(atSourceTime: .zero)

        frameCount = 0
    }

    func appendFrame(from texture: MTLTexture) throws {
        guard let adaptor = pixelBufferAdaptor,
              let pool = adaptor.pixelBufferPool else {
            throw ExportError.notStarted
        }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)

        guard let buffer = pixelBuffer else {
            throw ExportError.bufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let baseAddress = CVPixelBufferGetBaseAddress(buffer)!

        // Copy texture data to pixel buffer
        texture.getBytes(
            baseAddress,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                           size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0)

        let presentationTime = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps))

        while !videoInput!.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }

        adaptor.append(buffer, withPresentationTime: presentationTime)
        frameCount += 1
    }

    func appendFrame(from cgImage: CGImage) throws {
        guard let adaptor = pixelBufferAdaptor,
              let pool = adaptor.pixelBufferPool else {
            throw ExportError.notStarted
        }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)

        guard let buffer = pixelBuffer else {
            throw ExportError.bufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let baseAddress = CVPixelBufferGetBaseAddress(buffer)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Draw CGImage into the pixel buffer (BGRA format)
        guard let drawCtx = CGContext(data: baseAddress, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                       space: colorSpace,
                                       bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                                   CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw ExportError.bufferCreationFailed
        }
        drawCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let presentationTime = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps))

        while !videoInput!.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }

        adaptor.append(buffer, withPresentationTime: presentationTime)
        frameCount += 1
    }

    func finish() async throws {
        videoInput?.markAsFinished()
        await assetWriter?.finishWriting()

        if let error = assetWriter?.error {
            throw error
        }
    }

    enum ExportError: Error, CustomStringConvertible {
        case notStarted
        case bufferCreationFailed

        var description: String {
            switch self {
            case .notStarted: return "Video export not started"
            case .bufferCreationFailed: return "Failed to create pixel buffer"
            }
        }
    }
}
