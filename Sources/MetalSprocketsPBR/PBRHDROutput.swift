import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalSprockets
import MetalSupport
import UniformTypeIdentifiers

public extension OffscreenRenderer {
    /// An offscreen renderer with an rgba16Float color target (linear, extended range), for HDR output. Use
    /// ``PBRToneMapping/none`` to keep values above 1. The renderer uses reversed depth, so depth clears to 0.
    static func hdr(size: CGSize, device: MTLDevice? = nil) throws -> OffscreenRenderer {
        let device = device ?? _MTLCreateSystemDefaultDevice()
        let targetSize = PBRTargetSize(size)
        let color = try device.makeTargetTexture(.rgba16Float, size: targetSize, usage: [.renderTarget, .shaderRead], storageMode: .shared, label: "HDR Color Texture")
        let depth = try device.makeTargetTexture(.depth32Float, size: targetSize, usage: .renderTarget, label: "HDR Depth Texture")
        return try OffscreenRenderer(size: size, colorTexture: color, depthTexture: depth, clearDepth: 0)
    }
}

public extension MTLTexture {
    /// The pixels of a shared rgba16Float texture, row by row, four components each.
    func float16Pixels() throws -> [Float16] {
        guard pixelFormat == .rgba16Float, storageMode == .shared else {
            throw PBREnvironmentError.resourceCreationFailed("float16Pixels needs a shared rgba16Float texture")
        }
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            getBytes(bytes.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    /// A half-float image in extended linear sRGB (values above 1 kept) from a shared rgba16Float texture.
    func hdrCGImage() throws -> CGImage {
        let pixels = try float16Pixels()
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data),
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else {
            throw PBREnvironmentError.resourceCreationFailed("HDR image")
        }
        return image
    }
}

public extension CGImage {
    /// Writes the image as OpenEXR.
    func writeEXR(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.exr.identifier as CFString, 1, nil) else {
            throw PBREnvironmentError.resourceCreationFailed("EXR destination")
        }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PBREnvironmentError.resourceCreationFailed("EXR write")
        }
    }
}
