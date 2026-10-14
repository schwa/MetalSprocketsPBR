import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalSprocketsPBRShaders
import MetalSupport
import simd

public enum PBREnvironmentError: Error {
    case unreadableImage(URL)
    case resourceCreationFailed(String)
}

/// Image-based lighting for ``PBRRenderer``: an HDR environment prefiltered for the split-sum approximation.
///
/// Build once (it runs GPU work and waits for it) and share between renderers. Immutable after init.
public final class PBREnvironment: @unchecked Sendable {
    public enum Source: Sendable {
        /// A procedural neutral photo studio. Needs no files.
        case studio
        /// The same radiance in every direction (linear RGB).
        case uniform(SIMD3<Float>)
        /// An equirectangular HDR image (.hdr, .exr, or any format ImageIO reads).
        case equirectangular(URL)
        /// Linear equirectangular radiance, RGBA half floats, `width` x `height`, row 0 is +Y (see `source`).
        case equirectangularPixels(width: Int, height: Int, rgba: [Float16])
    }

    /// Linear equirectangular radiance (rgba16Float) with a full mip chain. Row 0 is +Y.
    public let source: MTLTexture
    /// Cosine-convolved radiance (irradiance / pi).
    public let irradiance: MTLTexture
    /// GGX-prefiltered radiance; mip level = perceptual roughness × (mipLevelCount - 1).
    public let specular: MTLTexture
    /// Split-sum BRDF integral, indexed by (NdotV, perceptual roughness).
    public let brdfLookup: MTLTexture

    /// Shared studio environment on the default device.
    ///
    /// Building it only fails if the Metal device or the package's shader library is unavailable, in which case
    /// nothing can render anyway.
    public static let studio: PBREnvironment = {
        do {
            return try PBREnvironment(source: .studio)
        } catch {
            fatalError("Cannot build the studio environment: \(error)")
        }
    }()

    public convenience init(source: Source, device: MTLDevice? = nil, specularSize: Int = 256, irradianceSize: Int = 32) throws {
        let device = device ?? _MTLCreateSystemDefaultDevice()
        let builder = try Builder(device: device)
        let sourceTexture: MTLTexture
        switch source {
        case .studio:
            sourceTexture = try builder.generateEquirect(width: 2_048, height: 1_024, kernel: "equirect_studio", color: nil)

        case .uniform(let color):
            sourceTexture = try builder.generateEquirect(width: 64, height: 32, kernel: "equirect_uniform", color: SIMD4(color, 1))

        case .equirectangular(let url):
            sourceTexture = try builder.loadEquirect(url)

        case let .equirectangularPixels(width, height, rgba):
            precondition(rgba.count == width * height * 4, "One RGBA value per pixel")
            sourceTexture = try builder.uploadEquirect(rgba, width: width, height: height)
        }
        try self.init(builder: builder, source: sourceTexture, specularSize: specularSize, irradianceSize: irradianceSize)
    }

    /// An environment from a cube map of radiance, such as an ARKit environment probe's texture (read before the
    /// probe goes away). `colorMatrix` converts its colors to linear sRGB (``displayP3ToLinearSRGB`` for ARKit);
    /// `scale` multiplies its brightness. The cube is resampled to an equirectangular source at most 1024 wide.
    public convenience init(cube: MTLTexture, colorMatrix: simd_float3x3 = matrix_identity_float3x3, scale: Float = 1, device: MTLDevice? = nil, specularSize: Int = 128, irradianceSize: Int = 32) throws {
        let device = device ?? cube.device
        let builder = try Builder(device: device)
        let width = min(cube.width * 4, 1_024)
        let sourceTexture = try builder.equirectFromCube(cube, width: width, height: width / 2, colorMatrix: colorMatrix, scale: scale)
        try self.init(builder: builder, source: sourceTexture, specularSize: specularSize, irradianceSize: irradianceSize)
    }

    /// Linear Display P3 to linear sRGB (both D65).
    public static let displayP3ToLinearSRGB = simd_float3x3(rows: [
        [1.2249, -0.2247, 0],
        [-0.0420, 1.0419, 0],
        [-0.0197, -0.0786, 1.0979]
    ])

    private init(builder: Builder, source: MTLTexture, specularSize: Int, irradianceSize: Int) throws {
        self.source = source
        specular = try builder.prefilterSpecular(source, size: specularSize)
        irradiance = try builder.convolveIrradiance(source, size: irradianceSize)
        brdfLookup = try Self.brdfLookups.lookup(builder: builder)
    }

    /// The split-sum BRDF table depends on nothing but the device, so it is built once per device.
    private static let brdfLookups = BRDFLookupCache()

    // @unchecked: MTLTexture is not Sendable, so Mutex cannot hold it; `lock` guards `lookups`, the only state, and
    // the textures are never written after they are built.
    private final class BRDFLookupCache: @unchecked Sendable {
        private let lock = NSLock()
        private var lookups: [ObjectIdentifier: MTLTexture] = [:]

        func lookup(builder: Builder) throws -> MTLTexture {
            let key = ObjectIdentifier(builder.device)
            if let cached = lock.withLock({ lookups[key] }) {
                return cached
            }
            let built = try builder.makeBRDFLookup(size: 128)
            return lock.withLock {
                if let raced = lookups[key] {
                    return raced
                }
                lookups[key] = built
                return built
            }
        }
    }

    /// Half-float RGBA pixels of `source` at the largest mip no wider than `maxWidth`, rows bottom-up (WebGL order).
    public func equirectangularPixels(maxWidth: Int) -> (width: Int, height: Int, data: Data) {
        var level = 0
        while (source.width >> level) > maxWidth, level < source.mipmapLevelCount - 1 {
            level += 1
        }
        let width = max(source.width >> level, 1)
        let height = max(source.height >> level, 1)
        let rowBytes = width * 8
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { buffer in
            let base = buffer.baseAddress!
            for row in 0 ..< height {
                // Flip vertically: WebGL textures start at the bottom row.
                source.getBytes(base + (height - 1 - row) * rowBytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, row, width, 1), mipmapLevel: level)
            }
        }
        return (width, height, data)
    }
}

/// One-off GPU work for building an environment.
private struct Builder {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw PBREnvironmentError.resourceCreationFailed("command queue")
        }
        self.queue = queue
        library = try device.makeDefaultLibrary(bundle: .metalSprocketsPBRShaders())
    }

    func pipeline(_ name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: "PBRIBL::\(name)") else {
            throw PBREnvironmentError.resourceCreationFailed("function \(name)")
        }
        return try device.makeComputePipelineState(function: function)
    }

    func makeTexture(_ descriptor: MTLTextureDescriptor, label: String) throws -> MTLTexture {
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PBREnvironmentError.resourceCreationFailed(label)
        }
        texture.label = label
        return texture
    }

    func run(_ encode: (MTLComputeCommandEncoder) throws -> Void, thenGenerateMipmapsFor mipmapped: MTLTexture? = nil) throws {
        guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PBREnvironmentError.resourceCreationFailed("command buffer")
        }
        try encode(encoder)
        encoder.endEncoding()
        if let mipmapped, mipmapped.mipmapLevelCount > 1, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: mipmapped)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw error
        }
    }

    func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int, depth: Int = 1) {
        encoder.setComputePipelineState(pipeline)
        let threads = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: depth), threadsPerThreadgroup: threads)
    }

    func equirectDescriptor(width: Int, height: Int) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite]
        return descriptor
    }

    func generateEquirect(width: Int, height: Int, kernel: String, color: SIMD4<Float>?) throws -> MTLTexture {
        let texture = try makeTexture(equirectDescriptor(width: width, height: height), label: "PBR Environment Source")
        let pipeline = try pipeline(kernel)
        try run({ encoder in
            encoder.setTexture(texture, index: 0)
            if var color {
                encoder.setBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            }
            dispatch(encoder, pipeline, width: width, height: height)
        }, thenGenerateMipmapsFor: texture)
        return texture
    }

    func loadEquirect(_ url: URL) throws -> MTLTexture {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary)
        else {
            throw PBREnvironmentError.unreadableImage(url)
        }
        let width = image.width
        let height = image.height
        // Decode to linear 32-bit float RGBA, then pack to half floats for a filterable, mipmappable texture.
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let pixels = context.data
        else {
            throw PBREnvironmentError.unreadableImage(url)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let floats = pixels.assumingMemoryBound(to: Float.self)
        var halves = [Float16](repeating: 0, count: width * height * 4)
        for index in halves.indices {
            halves[index] = Float16(floats[index])
        }
        return try uploadEquirect(halves, width: width, height: height)
    }

    func equirectFromCube(_ cube: MTLTexture, width: Int, height: Int, colorMatrix: simd_float3x3, scale: Float) throws -> MTLTexture {
        let texture = try makeTexture(equirectDescriptor(width: width, height: height), label: "PBR Environment Source")
        let pipeline = try pipeline("equirect_from_cube")
        var colorMatrix = colorMatrix
        var scale = scale
        try run({ encoder in
            encoder.setTexture(cube, index: 0)
            encoder.setTexture(texture, index: 1)
            encoder.setBytes(&colorMatrix, length: MemoryLayout<simd_float3x3>.stride, index: 0)
            encoder.setBytes(&scale, length: MemoryLayout<Float>.stride, index: 1)
            dispatch(encoder, pipeline, width: width, height: height)
        }, thenGenerateMipmapsFor: texture)
        return texture
    }

    func uploadEquirect(_ halves: [Float16], width: Int, height: Int) throws -> MTLTexture {
        let texture = try makeTexture(equirectDescriptor(width: width, height: height), label: "PBR Environment Source")
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: halves, bytesPerRow: width * 8)
        try run({ _ in }, thenGenerateMipmapsFor: texture)
        return texture
    }

    func makeCube(size: Int, mipmapped: Bool, label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: mipmapped)
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try makeTexture(descriptor, label: label)
    }

    func prefilterSpecular(_ source: MTLTexture, size: Int) throws -> MTLTexture {
        // Stop at 8×8 faces; smaller levels add little for the roughest materials.
        let mipCount = max(Int(log2(Double(size))) - 2, 1)
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: true)
        descriptor.mipmapLevelCount = mipCount
        descriptor.usage = [.shaderRead, .shaderWrite]
        let cube = try makeTexture(descriptor, label: "PBR Environment Specular")
        let pipeline = try pipeline("prefilter_specular")
        try run { encoder in
            for level in 0 ..< mipCount {
                guard let view = cube.makeTextureView(pixelFormat: .rgba16Float, textureType: .typeCube, levels: level ..< level + 1, slices: 0 ..< 6) else {
                    throw PBREnvironmentError.resourceCreationFailed("specular mip view")
                }
                var parameters = PBRPrefilterParameters(roughness: Float(level) / Float(max(mipCount - 1, 1)), sampleCount: 512)
                encoder.setTexture(source, index: 0)
                encoder.setTexture(view, index: 1)
                encoder.setBytes(&parameters, length: MemoryLayout<PBRPrefilterParameters>.stride, index: 0)
                let faceSize = max(size >> level, 1)
                dispatch(encoder, pipeline, width: faceSize, height: faceSize, depth: 6)
            }
        }
        return cube
    }

    func convolveIrradiance(_ source: MTLTexture, size: Int) throws -> MTLTexture {
        let cube = try makeCube(size: size, mipmapped: false, label: "PBR Environment Irradiance")
        let pipeline = try pipeline("convolve_irradiance")
        try run { encoder in
            var parameters = PBRPrefilterParameters(roughness: 1, sampleCount: 1_024)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(cube, index: 1)
            encoder.setBytes(&parameters, length: MemoryLayout<PBRPrefilterParameters>.stride, index: 0)
            dispatch(encoder, pipeline, width: size, height: size, depth: 6)
        }
        return cube
    }

    func makeBRDFLookup(size: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try makeTexture(descriptor, label: "PBR BRDF Lookup")
        let pipeline = try pipeline("brdf_lookup")
        try run { encoder in
            encoder.setTexture(texture, index: 0)
            dispatch(encoder, pipeline, width: size, height: size)
        }
        return texture
    }
}
