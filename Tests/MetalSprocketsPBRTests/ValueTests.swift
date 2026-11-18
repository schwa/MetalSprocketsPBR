import GeometryLite3D
import Metal
import MetalSprockets
@testable import MetalSprocketsPBR
import MetalSprocketsPBRShaders
import simd
import Testing

struct ValueTests {
    @Test
    func frameBindingsFillPlaceholdersForWhatIsOff() throws {
        var lighting = PBRLighting(exposure: 2)
        lighting.ambientOcclusion = nil
        let bindings = try PBRFrameBindings(lighting: lighting, viewProjections: [matrix_identity_float4x4], cameraPositions: [[1, 2, 3]])
        #expect(bindings.lights.count == 1)
        #expect(bindings.frame.lightCount == 0)
        #expect(bindings.frame.exposure == 2)
        #expect(bindings.frame.cameraPositions.0 == [1, 2, 3])
        #expect(bindings.frame.cameraPositions.1 == [1, 2, 3])
        #expect(bindings.shadow.enabled == 0)
        #expect(bindings.frame.ambientOcclusionStrength == 0)
    }

    @Test
    func cameraFramingKeepsBoundsInView() {
        let bounds = BoundingBox3D(min: [-1, -1, -1], max: [1, 1, 1])
        for aspectRatio: Float in [0.5, 2] {
            let camera = PBRCamera.framing(bounds, aspectRatio: aspectRatio)
            let frustum = Frustum(viewProjection: camera.projectionMatrix * camera.viewMatrix)
            #expect(frustum.intersects(bounds))
        }
        let explicit = PBRCamera(viewMatrix: matrix_identity_float4x4, projectionMatrix: matrix_identity_float4x4)
        #expect(explicit.viewMatrix == matrix_identity_float4x4)
    }

    @Test
    func lightingHelpers() {
        let directional = LightingLight.directional(direction: [0, -2, 0], color: [1, 0, 0], intensity: 3)
        #expect(directional.type == .directional)
        #expect(directional.direction == [0, -1, 0])
        #expect(directional.intensity == 3)
        let point = LightingLight.point(position: [1, 2, 3], range: 5)
        #expect(point.type == .point)
        #expect(point.position == [1, 2, 3])
        #expect(point.range == 5)

        var lighting = PBRLighting.default
        #expect(lighting.lights.isEmpty)
        lighting.environmentRotation = .pi / 2
        let rotated = lighting.environmentRotationMatrix * SIMD3<Float>(1, 0, 0)
        #expect(simd_distance(rotated, [0, 0, 1]) < 1e-5)
    }

    @Test
    func enumNamesAndShaderValues() {
        #expect(Set(PBRDebugView.allCases.map(\.name)).count == PBRDebugView.allCases.count)
        for view in PBRDebugView.allCases {
            #expect(view.id == view)
            #expect(view.shaderValue.rawValue == view.rawValue)
        }
        #expect(Set(LightingToneMapping.allCases.map(\.name)).count == LightingToneMapping.allCases.count)
        for toneMapping in LightingToneMapping.allCases {
            #expect(toneMapping.id == toneMapping)
            #expect(toneMapping.shaderValue.rawValue == toneMapping.rawValue)
        }
    }

    @Test
    func textureTransformComposesTranslationRotationScale() {
        var transform = PBRMaterial.TextureTransform(slot: \.baseColor, offset: [1, 2], rotation: 0, scale: [2, 3])
        #expect(transform.matrix * SIMD3<Float>(1, 1, 1) == [3, 5, 1])
        transform.rotation = .pi / 2
        let rotated = transform.matrix * SIMD3<Float>(1, 0, 1)
        #expect(simd_distance(rotated, [1, 0, 1]) < 1e-5)
    }

    @Test
    func stereoViews() {
        let left = simd_float4x4(translation: [1, 0, 0])
        let right = simd_float4x4(translation: [-1, 0, 0])
        let viewport = MTLViewport(originX: 0, originY: 0, width: 1, height: 1, znear: 0, zfar: 1)
        let stereo = StereoViews(viewMatrices: [left, right], projectionMatrices: [matrix_identity_float4x4, matrix_identity_float4x4], viewports: [viewport, viewport])
        #expect(stereo.count == 2)
        #expect(stereo.viewProjections == [left, right])
        #expect(stereo.cameraPositions == [[-1, 0, 0], [1, 0, 0]])
        #expect(viewPair([1]) == (1, 1))
        #expect(viewPair([1, 2]) == (1, 2))

        let views = PBRViews(viewMatrix: matrix_identity_float4x4, projectionMatrix: matrix_identity_float4x4, stereo: stereo)
        #expect(views.isStereo && views.viewProjections == [left, right])
        #expect(views.centerPosition == .zero, "Between the eyes")
        #expect(views.inverseRotationViewProjections == [matrix_identity_float4x4, matrix_identity_float4x4], "Translation is dropped")
        let mono = PBRViews(viewMatrix: left, projectionMatrix: matrix_identity_float4x4, stereo: nil)
        #expect(!mono.isStereo && mono.cameraPositions == [[-1, 0, 0]] && mono.centerPosition == [-1, 0, 0])
    }
}
