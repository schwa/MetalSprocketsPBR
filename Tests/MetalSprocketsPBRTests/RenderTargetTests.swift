import Metal
@testable import MetalSprocketsPBR
import Testing

struct RenderTargetTests {
    let device = MTLCreateSystemDefaultDevice()!

    @Test func transmissionCacheFollowsSizeAndViewCount() throws {
        let cache = PBRTargetCache<PBRTransmissionTarget>()
        let first = try cache.target(for: .init(width: 64, height: 48, device: device))
        #expect(try cache.target(for: .init(width: 64, height: 48, device: device)) === first)
        #expect(cache.target === first)
        let stereo = try cache.target(for: .init(width: 64, height: 48, viewCount: 2, device: device))
        #expect(stereo !== first && stereo.viewCount == 2)
        let resized = try cache.target(for: .init(width: 0, height: 48, viewCount: 2, device: device))
        #expect(resized.width == 1 && resized.height == 48)
    }

    @Test(.requiresMetal4) func upscaleCacheScalesInputAndKeepsOutputSize() throws {
        let cache = PBRTargetCache<PBRUpscaleTargets>()
        let upscaling = PBRUpscaling(scale: 0.5)
        let targets = try cache.target(for: .init(upscaling: upscaling, outputSize: CGSize(width: 100, height: 60), device: device))
        #expect(targets.color.width == 50 && targets.color.height == 30)
        #expect(targets.depth.width == 50 && targets.output.width == 100 && targets.output.height == 60)
        #expect(try cache.target(for: .init(upscaling: upscaling, outputSize: CGSize(width: 100, height: 60), device: device)).color === targets.color)
        let rescaled = try cache.target(for: .init(upscaling: PBRUpscaling(scale: 0.01), outputSize: CGSize(width: 100, height: 60), device: device))
        #expect(rescaled.color.width == 10, "Scale clamps to 0.1")
    }

    @Test func transmissionTargetTexturesAreLayered() throws {
        let target = try PBRTransmissionTarget(device: device, width: 8, height: 4, viewCount: 2)
        #expect(target.color.textureType == .type2DArray && target.color.arrayLength == 2 && target.color.mipmapLevelCount > 1)
        #expect(target.depth.arrayLength == 2 && target.depth.pixelFormat == .depth32Float)
        let backdrop = try target.backdrop()
        #expect(try target.backdrop() === backdrop)
        #expect(backdrop.arrayLength == 2 && backdrop.mipmapLevelCount == target.color.mipmapLevelCount)
    }

    @Test(.requiresMetal4) func sharedResourcesAreMadeOnTheGivenDevice() throws {
        let shaders = try PBRShaders.shared(device: device)
        #expect(shaders.placeholderTexture.device === device && shaders.environmentSampler.device === device)
        #expect(try PBRShaders.shared(device: device).placeholderTexture === shaders.placeholderTexture, "Made once per device")
        #expect(try PBRTargetCache<PBRTransmissionTarget>().target(for: .init(width: 4, height: 4, device: device)).color.device === device)
    }
}
