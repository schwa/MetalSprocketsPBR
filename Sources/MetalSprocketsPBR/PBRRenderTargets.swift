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
            throw PBREnvironmentError.resourceCreationFailed(label)
        }
        texture.label = label
        return texture
    }
}

/// One value kept across frames, remade when its key changes (e.g. the viewport size).
final class PBRKeyedCache<Key: Equatable, Value> {
    private var entry: (key: Key, value: Value)?

    var value: Value? { entry?.value }

    func value(for key: Key, make: () throws -> Value) rethrows -> Value {
        if let entry, entry.key == key {
            return entry.value
        }
        let value = try make()
        entry = (key, value)
        return value
    }
}

struct PBRUpscaleTargets {
    var color: MTLTexture
    var depth: MTLTexture
    var output: MTLTexture
    var resources: ResourceCollection

    init(upscaling: PBRUpscaling, outputSize: PBRTargetSize) throws {
        let device = _MTLCreateSystemDefaultDevice()
        let inputSize = outputSize.scaled(by: upscaling.scale)
        color = try device.makeTargetTexture(upscaling.colorPixelFormat, size: inputSize, usage: [.renderTarget, .shaderRead], label: "PBR Upscale Input")
        depth = try device.makeTargetTexture(upscaling.depthPixelFormat, size: inputSize, usage: [.renderTarget], label: "PBR Upscale Depth")
        output = try device.makeTargetTexture(upscaling.colorPixelFormat, size: outputSize, usage: [.renderTarget, .shaderRead, .shaderWrite], label: "PBR Upscale Output")
        resources = try ResourceCollection(device: device)
        for texture in [color, depth, output] {
            try resources.register(texture)
        }
    }
}

/// Low-resolution and upscaled targets for the current size and settings, recreated when they change.
final class PBRUpscaleTargetCache {
    private struct Key: Equatable {
        var upscaling: PBRUpscaling
        var size: PBRTargetSize
    }

    private let cache = PBRKeyedCache<Key, PBRUpscaleTargets>()

    func targets(for upscaling: PBRUpscaling, outputSize: CGSize) throws -> PBRUpscaleTargets {
        let size = PBRTargetSize(outputSize)
        return try cache.value(for: Key(upscaling: upscaling, size: size)) {
            try PBRUpscaleTargets(upscaling: upscaling, outputSize: size)
        }
    }
}

/// A transmission target for the current viewport size, recreated when the size changes.
final class PBRTransmissionTargetCache {
    private struct Key: Equatable {
        var size: PBRTargetSize
        var viewCount: Int
    }

    private let cache = PBRKeyedCache<Key, PBRTransmissionTarget>()

    var target: PBRTransmissionTarget? { cache.value }

    func target(width: Int, height: Int, viewCount: Int = 1) throws -> PBRTransmissionTarget {
        let size = PBRTargetSize(width: width, height: height)
        return try cache.value(for: Key(size: size, viewCount: max(viewCount, 1))) {
            try PBRTransmissionTarget(width: size.width, height: size.height, viewCount: viewCount)
        }
    }
}
