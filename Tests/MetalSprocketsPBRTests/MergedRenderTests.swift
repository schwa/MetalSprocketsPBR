import CoreGraphics
import Metal
import MetalSprockets
@testable import MetalSprocketsPBR
import MetalSprocketsPBRShaders
import simd
import SwiftMesh
import Testing

@Suite(.requiresMetal4)
@MainActor
struct MergedRenderTests {
    let models: TestModels
    let size = CGSize(width: 32, height: 32)
    let view = simd_float4x4.lookAt(eye: [0, 0, 3], target: .zero, up: [0, 1, 0])
    let projection = simd_float4x4.perspective(fovY: .pi / 3, aspectRatio: 1, near: 0.1, far: 20)

    init() throws {
        models = try TestModels()
    }

    /// Two opaque quads, two double-sided glass quads, and two skinned quads (two skins), all in one geometry, so each
    /// set merges.
    func mergeableModel() throws -> PBRModel {
        var geometry = PBRGeometryBuilder(device: models.device)
        let positions: [SIMD3<Float>] = [[-0.2, -0.2, 0], [0.2, -0.2, 0], [0.2, 0.2, 0], [-0.2, 0.2, 0]]
        let normals = [SIMD3<Float>](repeating: [0, 0, 1], count: 4)
        let quad = try geometry.add(attributes: [.positions(positions), .normals(normals)], indices: [0, 1, 2, 0, 2, 3])
        let skinned = try geometry.add(attributes: [
            .positions(positions), .normals(normals),
            .jointIndices(Array(repeating: .zero, count: 4)), .jointWeights(Array(repeating: [1, 0, 0, 0], count: 4))
        ], indices: [0, 1, 2, 0, 2, 3])
        let primitives = try geometry.build()
        let placements: [SIMD3<Float>] = [[-0.6, 0.5, 0], [0.6, 0.5, 0], [-0.6, -0.5, 0.5], [0.6, -0.5, 0.5], [-0.6, 0, -0.5], [0.6, 0, -0.5]]
        var builder = PBRModelBuilder(device: models.device, restPose: PBRPose(worldMatrices: placements.map { simd_float4x4(translation: $0) }))
        builder.skins = [PBRModel.Skin(joints: [4], inverseBindMatrices: [matrix_identity_float4x4]), PBRModel.Skin(joints: [5], inverseBindMatrices: [matrix_identity_float4x4])]
        builder.addInstance(primitives[quad], material: try models.material(), node: 0)
        builder.addInstance(primitives[quad], material: try models.material(color: [0, 1, 0, 1]), node: 1)
        builder.addInstance(primitives[quad], material: try models.material(transmission: 1, doubleSided: true), node: 2)
        builder.addInstance(primitives[quad], material: try models.material(color: [0, 0, 1, 1], transmission: 1, doubleSided: true), node: 3)
        builder.addInstance(primitives[skinned], material: try models.material(color: [1, 1, 0, 1]), node: 4, skin: 0)
        builder.addInstance(primitives[skinned], material: try models.material(color: [0, 1, 1, 1]), node: 5, skin: 1)
        return try builder.build()
    }

    func render(_ content: some Element) throws -> [SIMD4<UInt8>] {
        try rgbaPixels(OffscreenRenderer(size: size, clearDepth: 0).render(content).cgImage)
    }

    @Test
    func mergedSetsRender() throws {
        let model = try mergeableModel()
        #expect(model.merged != nil && model.mergedTransmissive != nil && model.mergedSkinned != nil)
        #expect(model.mergedSkinned?.jointPalette(skins: model.skins, pose: model.restPose).count == 2)
        var scene = PBRScene(model: model, viewMatrix: view, projectionMatrix: projection, viewportSize: size)
        scene.showsBackground = true
        let pixels = try render(scene)
        #expect(pixels.contains { Int($0.y) > Int($0.x) + 50 }, "The green merged quad is drawn")

        // Hiding nodes hides their merged records.
        var pose = model.restPose
        pose.visibility = [true, false, true, true, true, false]
        scene.pose = pose
        let hidden = try render(scene)
        #expect(!hidden.contains { Int($0.y) > Int($0.x) + 50 && Int($0.y) > Int($0.z) + 50 }, "The green quad is hidden")
    }

    @Test
    func materialAccessors() throws {
        let opaque = try models.material()
        let glass = try models.material(transmission: 1)
        #expect(opaque.canOverride(try models.material(color: [0, 0, 1, 1])))
        #expect(!opaque.canOverride(glass))
        #expect(opaque[texture: kPBRTextureBaseColor].texture === models.placeholder.texture)
    }

    @Test
    func stereoRendersBothViews() throws {
        let device = models.device
        func arrayTexture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 32, height: 32, mipmapped: false)
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = 2
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = format == .depth32Float ? .private : .shared
            return try #require(device.makeTexture(descriptor: descriptor))
        }
        let color = try arrayTexture(.rgba16Float)
        let renderer = try OffscreenRenderer(size: size, colorTexture: color, depthTexture: arrayTexture(.depth32Float), clearDepth: 0)
        renderer.renderPassDescriptor.renderTargetArrayLength = 2

        let viewport = MTLViewport(originX: 0, originY: 0, width: 32, height: 32, znear: 0, zfar: 1)
        let stereo = PBRStereoViews(
            viewMatrices: [simd_float4x4.lookAt(eye: [-0.1, 0, 3], target: .zero, up: [0, 1, 0]), simd_float4x4.lookAt(eye: [0.1, 0, 3], target: .zero, up: [0, 1, 0])],
            projectionMatrices: [projection, projection],
            viewports: [viewport, viewport]
        )
        let model = try mergeableModel()
        let target = try PBRTransmissionTarget(device: device, width: 32, height: 32, viewCount: 2)
        let pbr = PBRRenderer(model: model, viewMatrix: stereo.viewMatrices[0], projectionMatrix: projection, transmissionTarget: target).viewing(stereo)
        var background = PBREnvironmentBackground(lighting: pbr.lighting, viewMatrix: stereo.viewMatrices[0], projectionMatrix: projection)
        background.stereo = stereo
        _ = try renderer.render(try Group {
            PBRTransmissionPass(renderers: [pbr], target: target, showsBackground: true)
            try RenderPass {
                try Group {
                    background
                    pbr
                }
                .renderPipelineDescriptorTransformer { $0.maxVertexAmplificationCount = 2 }
            }
        })
        var pixel = [Float16](repeating: 0, count: 4)
        for slice in 0 ..< 2 {
            color.getBytes(&pixel, bytesPerRow: 32 * 8, bytesPerImage: 32 * 32 * 8, from: MTLRegionMake2D(16, 4, 1, 1), mipmapLevel: 0, slice: slice)
            #expect(Float(pixel[0]) > 0.1, "Slice \(slice) is drawn")
        }
    }
}
