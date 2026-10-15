import Metal
@testable import MetalSprocketsPBR
import simd
import Testing

@Suite(.requiresMetal4)
struct EnvironmentTests {
    let device = MTLCreateSystemDefaultDevice()!

    func averageRed(_ environment: PBREnvironment) -> Float {
        let (width, height, data) = environment.equirectangularPixels(maxWidth: 8)
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        return stride(from: 0, to: values.count, by: 4).map { Float(values[$0]) }.reduce(0, +) / Float(width * height)
    }

    @Test
    func uniformEnvironment() throws {
        let environment = try PBREnvironment(source: .uniform([0.5, 0, 0]), device: device, specularSize: 16, irradianceSize: 8)
        let (width, height, data) = environment.equirectangularPixels(maxWidth: 8)
        #expect(width == 8 && height == 4)
        #expect(data.count == width * height * 8)
        #expect(abs(averageRed(environment) - 0.5) < 0.01)
    }

    @Test
    func pixelEnvironment() throws {
        let rgba = [Float16](repeating: 0.25, count: 4 * 2 * 4)
        let environment = try PBREnvironment(source: .equirectangularPixels(width: 4, height: 2, rgba: rgba), device: device, specularSize: 16, irradianceSize: 8)
        #expect(environment.source.width == 4)
        #expect(abs(averageRed(environment) - 0.25) < 0.01)
    }

    @Test
    func cubeEnvironmentAppliesScale() throws {
        let size = 4
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: false)
        descriptor.usage = .shaderRead
        let cube = try #require(device.makeTexture(descriptor: descriptor))
        let face = [Float16](repeating: 1, count: size * size * 4)
        for slice in 0 ..< 6 {
            cube.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: slice, withBytes: face, bytesPerRow: size * 8, bytesPerImage: size * size * 8)
        }
        let environment = try PBREnvironment(cube: cube, scale: 2, specularSize: 16, irradianceSize: 8)
        #expect(environment.source.width == 16)
        #expect(abs(averageRed(environment) - 2) < 0.05)
    }
}
