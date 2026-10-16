import CoreGraphics
import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
@testable import MetalSprocketsPBR
import MetalSprocketsPBRShaders
import simd
import SwiftMesh
import Testing

/// RGBA8 pixels of `image`, row 0 at the top.
func rgbaPixels(_ image: CGImage) throws -> [SIMD4<UInt8>] {
    let width = image.width
    let height = image.height
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = try #require(context.data).assumingMemoryBound(to: SIMD4<UInt8>.self)
    return Array(UnsafeBufferPointer(start: pixels, count: width * height))
}

extension TestModels {
    /// A quad whose vertices all follow joint 0 of a one-joint skin, with one morph target moving it up by 1.
    func skinnedMorphedQuad(skinned: Bool, morphed: Bool) throws -> PBRModel.Primitive {
        var geometry = PBRGeometryBuilder(device: device)
        let positions: [SIMD3<Float>] = [[-0.5, -0.5, 0], [0.5, -0.5, 0], [0.5, 0.5, 0], [-0.5, 0.5, 0]]
        var attributes: [MetalMesh.VertexAttributeData] = [.positions(positions), .normals(Array(repeating: [0, 0, 1], count: 4))]
        if skinned {
            attributes += [.jointIndices(Array(repeating: .zero, count: 4)), .jointWeights(Array(repeating: [1, 0, 0, 0], count: 4))]
        }
        let morphTargets = morphed ? MetalMesh.MorphTargets(targets: [.init(positionOffsets: Array(repeating: [0, 1, 0], count: 4))]) : nil
        try geometry.add(attributes: attributes, indices: [0, 1, 2, 0, 2, 3], morphTargets: morphTargets)
        return try geometry.build()[0]
    }

    func linesAndPoints() throws -> [PBRModel.Primitive] {
        var geometry = PBRGeometryBuilder(device: device)
        let positions: [SIMD3<Float>] = [[-0.5, 0, 0], [0.5, 0, 0]]
        try geometry.add(attributes: [.positions(positions)], indices: [0, 1], primitiveType: .line)
        try geometry.add(attributes: [.positions(positions)], indices: [0, 1], primitiveType: .point)
        return try geometry.build()
    }
}

@Suite(.requiresMetal4)
@MainActor
struct RenderTests {
    let models: TestModels
    let size = CGSize(width: 32, height: 32)
    let view = LookAt(position: [0, 0, 3], target: .zero, up: [0, 1, 0]).viewMatrix
    let projection = PerspectiveProjection(verticalAngleOfView: .radians(.pi / 3), depthMode: .reversed(zClip: 0.1 ... 20)).projectionMatrix(aspectRatio: 1)
    let lighting = PBRLighting(lights: [.directional(direction: [0, 0, -1], intensity: 3)])

    init() throws {
        models = try TestModels()
    }

    func scene(_ model: PBRModel, pose: PBRPose? = nil) -> PBRScene {
        PBRScene(model: model, viewMatrix: view, projectionMatrix: projection, lighting: lighting, pose: pose, viewportSize: size)
    }

    func render(_ content: some Element) throws -> [SIMD4<UInt8>] {
        try rgbaPixels(OffscreenRenderer(size: size, clearDepth: 0).render(content).cgImage)
    }

    var center: Int { Int(size.height) / 2 * Int(size.width) + Int(size.width) / 2 }

    @Test
    func drawsALitRedQuad() throws {
        let pixels = try render(scene(models.model([(.zero, models.material())])))
        #expect(pixels[center].x > 200 && pixels[center].y < 150, "\(pixels[center])")
        #expect(pixels[0] == [0, 0, 0, 255], "Nothing is drawn outside the quad")
    }

    @Test
    func backgroundFillsTheView() throws {
        var scene = scene(try models.model([(.zero, models.material())]))
        scene.showsBackground = true
        let pixels = try render(scene)
        #expect(pixels[0].w == 255)
    }

    @Test
    func multisampledAndWireframe() throws {
        var scene = scene(try models.model([(.zero, models.material())]))
        scene.sampleCount = 4
        scene.showsWireframe = true
        let pixels = try render(scene)
        #expect(pixels[center].x > 100)
    }

    @Test
    func upscaled() throws {
        guard PBRUpscaling.isSupported(device: models.device) else { return }
        for sampleCount in [1, 4] {
            var scene = scene(try models.model([(.zero, models.material())]))
            scene.upscaling = PBRUpscaling(scale: 0.5)
            scene.sampleCount = sampleCount
            let pixels = try render(scene)
            #expect(pixels[center].x > 100)
        }
    }

    @Test
    func everyDebugViewRenders() throws {
        let model = try models.model([(.zero, models.material()), ([0, 0, -1], models.material(transmission: 1))])
        for debugView in PBRDebugView.allCases where debugView != .lit {
            var scene = scene(model)
            scene.debugView = debugView
            _ = try render(scene)
        }
    }

    @Test
    func glassShowsWhatIsBehindIt() throws {
        let red = try models.material()
        let glass = try models.material(color: [1, 1, 1, 1], transmission: 1, doubleSided: true)
        let model = try models.model([([0, 0, -1], red), ([0, 0, 0.5], glass)])
        var scene = scene(model)
        scene.showsBackground = true
        let pixels = try render(scene)
        #expect(pixels[center].x > pixels[center].y, "Red seen through glass: \(pixels[center])")
    }

    @Test
    func transmissionPassAndRendererComposeByHand() throws {
        let model = try models.model([([0, 0, -1], models.material()), (.zero, models.material(transmission: 1))])
        let target = try PBRTransmissionTarget(device: models.device, size: 32)
        #expect(target.width == 32 && target.viewCount == 1)
        #expect(!target.hasBackdrop)
        let view = view
        let projection = projection
        let pixels = try render(try Group {
            PBRTransmissionPass(model: model, viewMatrix: view, projectionMatrix: projection, target: target, showsBackground: true)
            try RenderPass {
                PBREnvironmentBackground(environment: .studio, viewMatrix: view, projectionMatrix: projection, blur: 0.5)
                PBRRenderer(model: model, viewMatrix: view, projectionMatrix: projection, transmissionTarget: target)
            }
        })
        #expect(pixels[center].w == 255)
    }

    @Test
    func blendedQuadsOfSeveralModelsSortTogether() throws {
        let near = try models.model([([0, 0, 1], models.material(color: [1, 0, 0, 0.5], blended: true)), ([0.2, 0, 0.9], models.material(color: [1, 0, 0, 0.5], blended: true))])
        let far = try models.model([([0, 0, -1], models.material(color: [0, 0, 1, 0.5], blended: true))])
        let scene = PBRScene(items: [.init(model: near), .init(model: far)], viewMatrix: view, projectionMatrix: projection, lighting: lighting, viewportSize: size)
        let pixels = try render(scene)
        #expect(pixels[center].x > pixels[center].z, "Near red drawn over far blue: \(pixels[center])")
    }

    @Test
    func skinnedAndMorphedPrimitivesFollowThePose() throws {
        let material = try models.material()
        var builder = PBRModelBuilder(device: models.device, restPose: PBRPose(worldMatrices: [matrix_identity_float4x4, matrix_identity_float4x4], morphWeights: [[], [0]]))
        builder.skins = [PBRModel.Skin(joints: [0], inverseBindMatrices: [matrix_identity_float4x4])]
        builder.addInstance(try models.skinnedMorphedQuad(skinned: true, morphed: false), material: material, node: 0, skin: 0)
        builder.addInstance(try models.skinnedMorphedQuad(skinned: true, morphed: true), material: try models.material(color: [1, 0, 0, 0.5], blended: true), node: 0, skin: 0)
        builder.addInstance(try models.skinnedMorphedQuad(skinned: false, morphed: true), material: material, node: 1)
        let model = try builder.build()
        #expect(model.bounds(for: model.restPose) == model.bounds)

        // Moving the joint off screen takes the skinned quads with it; the morphed quad moves up by its weight.
        var pose = model.restPose
        pose.worldMatrices[0] = simd_float4x4(translation: [100, 0, 0])
        pose.morphWeights = [[], [1]]
        let pixels = try render(scene(model, pose: pose))
        let top = Int(size.width) * 6 + Int(size.width) / 2
        #expect(pixels[top].x > 100, "Morphed quad moved up: \(pixels[top])")
        #expect(model.skins[0].jointMatrices(for: pose) == [pose.worldMatrices[0]])

        // At rest, skinned draws use the rest pose.
        _ = try render(scene(model))
        // A hidden skinned mesh is not drawn.
        pose.visibility = [false, true]
        _ = try render(scene(model, pose: pose))
    }

    @Test
    func linesAndPointsDrawUnlit() throws {
        let primitives = try models.linesAndPoints()
        let material = try models.material(color: [0, 1, 0, 1])
        var builder = PBRModelBuilder(device: models.device, restPose: PBRPose(worldMatrices: [matrix_identity_float4x4]))
        for primitive in primitives {
            builder.addInstance(primitive, material: material, node: 0)
        }
        let model = try builder.build()
        let pixels = try render(scene(model))
        #expect(pixels.contains { $0.y > 200 })
        var renderer = PBRRenderer(model: model, viewMatrix: view, projectionMatrix: projection)
        renderer.drawsTrianglesOnly = true
        let skipped = try render(try RenderPass { renderer })
        #expect(!skipped.contains { $0.y > 200 })
    }

    @Test
    func posedMirroredAndHiddenInstances() throws {
        let model = try models.model([([-0.6, 0, 0], models.material()), ([0.6, 0, 0], models.material(color: [0, 1, 0, 1]))])
        var pose = model.restPose
        pose.worldMatrices[0] = simd_float4x4(translation: [-0.6, 0, 0]) * simd_float4x4(scale: [-1, 1, 1])
        pose.visibility = [true, false]
        var scene = scene(model, pose: pose)
        // Mirrored by both the pose and the model matrix: still facing the camera.
        scene.modelMatrix = simd_float4x4(scale: [-1, 1, 1])
        scene.materialOverrides = [models.quad.key: try models.material(color: [0, 0, 1, 1])]
        scene.pose = pose
        scene.model = model
        #expect(scene.model === model)
        #expect(scene.pose?.visibility == [true, false])
        #expect(scene.modelMatrix == simd_float4x4(scale: [-1, 1, 1]))
        #expect(scene.materialOverrides.count == 1)
        let pixels = try render(scene)
        #expect(!pixels.contains { Int($0.y) > Int($0.z) + 50 }, "The hidden green quad is not drawn")
        #expect(pixels.contains { Int($0.z) > Int($0.x) + 50 }, "The override draws blue")
    }

    @Test
    func shadowScalesOnlyItsOwnLight() throws {
        let model = try models.model([(.zero, models.material())])
        let darkRoom = try PBREnvironment(source: .uniform(.zero), device: models.device)
        // Depth 0 everywhere: with lessEqual, every fragment behind it (depth 0.5) is in shadow.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 4, height: 4, mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let map = try #require(models.device.makeTexture(descriptor: descriptor))
        let zeros = [Float](repeating: 0, count: 16)
        map.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, slice: 0, withBytes: zeros, bytesPerRow: 16, bytesPerImage: 64)
        var lightToShadowSpace = matrix_identity_float4x4
        lightToShadowSpace.columns.3.z = 0.5
        let shadows = PBRShadows(map: map, sliceViewProjections: [lightToShadowSpace], filterRadius: 0)

        var shadowed = PBRLight.directional(direction: [0, 0, -1], intensity: 0.5)
        shadowed.shadowSliceStart = 0
        shadowed.shadowSliceCount = 1
        let unshadowed = PBRLight.directional(direction: [0, 0, -1], intensity: 0.5)

        func center(_ lights: [PBRLight], shadows: PBRShadows?) throws -> SIMD4<UInt8> {
            var lighting = PBRLighting(lights: lights, environment: darkRoom)
            lighting.shadows = shadows
            let scene = PBRScene(model: model, viewMatrix: view, projectionMatrix: projection, lighting: lighting, viewportSize: size)
            return try render(scene)[self.center]
        }

        let one = try center([unshadowed], shadows: nil)
        let both = try center([shadowed, unshadowed], shadows: nil)
        let oneShadowed = try center([shadowed, unshadowed], shadows: shadows)
        #expect(Int(both.x) > Int(one.x) + 10, "Without a map, the shadowed light still lights: \(both) vs \(one)")
        #expect(abs(Int(oneShadowed.x) - Int(one.x)) <= 1, "Only the shadowed light is removed: \(oneShadowed) vs \(one)")
    }

    @Test
    func hdrOutputKeepsValuesAboveOne() throws {
        var uniforms = PBRMaterialUniforms.defaults(baseColor: [0, 0, 0, 1], metallic: 0, roughness: 1)
        uniforms.emissiveFactor = [1, 1, 1]
        uniforms.emissiveStrength = 4
        let material = try PBRMaterial(uniforms: uniforms, placeholder: models.placeholder, device: models.device)
        let model = try models.model([(.zero, material)])
        let renderer = try OffscreenRenderer.hdr(size: size, device: models.device)
        let scene = PBRScene(model: model, viewMatrix: view, projectionMatrix: projection, lighting: PBRLighting(environment: try PBREnvironment(source: .uniform(.zero), device: models.device), toneMapping: .none), viewportSize: size)
        let texture = try renderer.render(scene).texture
        let pixels = try texture.float16Pixels()
        #expect(pixels[center * 4] > 2)
        let image = try texture.hdrCGImage()
        #expect(image.width == 32)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).exr")
        defer { try? FileManager.default.removeItem(at: url) }
        try image.writeEXR(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // An EXR is a valid equirectangular environment.
        let environment = try PBREnvironment(source: .equirectangular(url), device: models.device, specularSize: 16, irradianceSize: 8)
        #expect(environment.source.width == 32)
        #expect(throws: PBREnvironmentError.self) {
            try PBREnvironment(source: .equirectangular(URL(fileURLWithPath: "/nonexistent.exr")), device: models.device)
        }
        #expect(throws: PBREnvironmentError.self) {
            try OffscreenRenderer(size: size, device: models.device).colorTexture.float16Pixels()
        }
        #expect(throws: PBREnvironmentError.self) {
            try image.writeEXR(to: URL(fileURLWithPath: "/nonexistent/directory/image.exr"))
        }
    }
}
