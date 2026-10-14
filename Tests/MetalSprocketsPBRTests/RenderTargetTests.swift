import Metal
@testable import MetalSprocketsPBR
import Testing

struct RenderTargetTests {
    @Test func transmissionCacheFollowsSizeAndViewCount() throws {
        let cache = PBRTransmissionTargetCache()
        let first = try cache.target(width: 64, height: 48)
        #expect(try cache.target(width: 64, height: 48) === first)
        #expect(cache.target === first)
        let stereo = try cache.target(width: 64, height: 48, viewCount: 2)
        #expect(stereo !== first && stereo.viewCount == 2)
        let resized = try cache.target(width: 0, height: 48, viewCount: 2)
        #expect(resized.width == 1 && resized.height == 48)
    }

    @Test(.requiresMetal4) func upscaleCacheScalesInputAndKeepsOutputSize() throws {
        let cache = PBRUpscaleTargetCache()
        let upscaling = PBRUpscaling(scale: 0.5)
        let targets = try cache.targets(for: upscaling, outputSize: CGSize(width: 100, height: 60))
        #expect(targets.color.width == 50 && targets.color.height == 30)
        #expect(targets.depth.width == 50 && targets.output.width == 100 && targets.output.height == 60)
        #expect(try cache.targets(for: upscaling, outputSize: CGSize(width: 100, height: 60)).color === targets.color)
        let rescaled = try cache.targets(for: PBRUpscaling(scale: 0.01), outputSize: CGSize(width: 100, height: 60))
        #expect(rescaled.color.width == 10, "Scale clamps to 0.1")
    }

    @Test func transmissionTargetTexturesAreLayered() throws {
        let target = try PBRTransmissionTarget(width: 8, height: 4, viewCount: 2)
        #expect(target.color.textureType == .type2DArray && target.color.arrayLength == 2 && target.color.mipmapLevelCount > 1)
        #expect(target.depth.arrayLength == 2 && target.depth.pixelFormat == .depth32Float)
        let backdrop = try target.backdrop()
        #expect(try target.backdrop() === backdrop)
        #expect(backdrop.arrayLength == 2 && backdrop.mipmapLevelCount == target.color.mipmapLevelCount)
    }
}
