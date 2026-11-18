import CoreGraphics
import Metal
import MetalSprockets
import MetalSupport

/// A render target's size in pixels, at least 1×1.
struct PBRTargetSize: Hashable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    init(_ size: CGSize) {
        self.init(width: Int(size.width), height: Int(size.height))
    }

    /// This size scaled by `scale`, clamped to 0.1...1.
    func scaled(by scale: Float) -> Self {
        let scale = min(max(scale, 0.1), 1)
        return Self(width: Int((Float(width) * scale).rounded()), height: Int((Float(height) * scale).rounded()))
    }
}

extension MTLDevice {
    /// A 2D (or, with `arrayLength`, 2D array) render target texture; throws instead of returning nil.
    func makeTargetTexture(_ format: MTLPixelFormat, size: PBRTargetSize, usage: MTLTextureUsage, mipmapped: Bool = false, arrayLength: Int? = nil, storageMode: MTLStorageMode = .private, label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width, height: size.height, mipmapped: mipmapped)
        if let arrayLength {
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = arrayLength
        }
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        guard let texture = makeTexture(descriptor: descriptor) else {
            throw LightingEnvironmentError.resourceCreationFailed(label)
        }
        texture.label = label
        return texture
    }
}

/// A target made for a key, such as a size; ``PBRTargetCache`` makes a new one when the key changes.
protocol PBRCachedTarget {
    associatedtype Key: Equatable
    init(key: Key) throws
}

/// One target kept across frames, remade when its key changes (e.g. the viewport size).
final class PBRTargetCache<Target: PBRCachedTarget> {
    private var entry: (key: Target.Key, target: Target)?

    var target: Target? { entry?.target }

    func target(for key: Target.Key) throws -> Target {
        if let entry, entry.key == key {
            return entry.target
        }
        let target = try Target(key: key)
        entry = (key, target)
        return target
    }
}

/// Low-resolution and upscaled targets for MetalFX spatial upscaling.
struct PBRUpscaleTargets: PBRCachedTarget {
    struct Key: Equatable {
        var upscaling: PBRUpscaling
        var outputSize: PBRTargetSize
        var device: MTLDevice

        init(upscaling: PBRUpscaling, outputSize: CGSize, device: MTLDevice) {
            self.upscaling = upscaling
            self.outputSize = PBRTargetSize(outputSize)
            self.device = device
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.upscaling == rhs.upscaling && lhs.outputSize == rhs.outputSize && lhs.device === rhs.device
        }
    }

    var color: MTLTexture
    var depth: MTLTexture
    var output: MTLTexture
    var resources: ResourceCollection

    init(key: Key) throws {
        let device = key.device
        let inputSize = key.outputSize.scaled(by: key.upscaling.scale)
        color = try device.makeTargetTexture(key.upscaling.colorPixelFormat, size: inputSize, usage: [.renderTarget, .shaderRead], label: "PBR Upscale Input")
        depth = try device.makeTargetTexture(key.upscaling.depthPixelFormat, size: inputSize, usage: [.renderTarget], label: "PBR Upscale Depth")
        output = try device.makeTargetTexture(key.upscaling.colorPixelFormat, size: key.outputSize, usage: [.renderTarget, .shaderRead, .shaderWrite], label: "PBR Upscale Output")
        resources = try ResourceCollection(device: device)
        for texture in [color, depth, output] {
            try resources.register(texture)
        }
    }
}

extension PBRTransmissionTarget: PBRCachedTarget {
    struct Key: Equatable {
        var size: PBRTargetSize
        var viewCount: Int
        var device: MTLDevice

        init(width: Int, height: Int, viewCount: Int = 1, device: MTLDevice) {
            size = PBRTargetSize(width: width, height: height)
            self.viewCount = max(viewCount, 1)
            self.device = device
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.size == rhs.size && lhs.viewCount == rhs.viewCount && lhs.device === rhs.device
        }
    }

    convenience init(key: Key) throws {
        try self.init(device: key.device, width: key.size.width, height: key.size.height, viewCount: key.viewCount)
    }
}
