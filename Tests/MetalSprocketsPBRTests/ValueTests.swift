import GeometryLite3D
import Metal
@testable import MetalSprocketsPBR
import MetalSprocketsPBRShaders
import simd
import Testing

struct ValueTests {
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
    func orthographicMapsNearToOneAndFarToZero() {
        let matrix = simd_float4x4.orthographic(halfWidth: 2, halfHeight: 1, near: 1, far: 3)
        let near = matrix * SIMD4<Float>(2, 1, -1, 1)
        let far = matrix * SIMD4<Float>(0, 0, -3, 1)
        #expect(near == [1, 1, 1, 1])
        #expect(far.z == 0)
    }

    @Test
    func lightingHelpers() {
        let directional = PBRLight.directional(direction: [0, -2, 0], color: [1, 0, 0], intensity: 3)
        #expect(directional.type == .directional)
        #expect(directional.direction == [0, -1, 0])
        #expect(directional.intensity == 3)
        let point = PBRLight.point(position: [1, 2, 3], range: 5)
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
        #expect(Set(PBRToneMapping.allCases.map(\.name)).count == PBRToneMapping.allCases.count)
        for toneMapping in PBRToneMapping.allCases {
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
        let stereo = PBRStereoViews(viewMatrices: [left, right], projectionMatrices: [matrix_identity_float4x4, matrix_identity_float4x4], viewports: [viewport, viewport])
        #expect(stereo.count == 2)
        #expect(stereo.viewProjections == [left, right])
        #expect(stereo.cameraPositions == [[-1, 0, 0], [1, 0, 0]])
        #expect(viewPair([1]) == (1, 1))
        #expect(viewPair([1, 2]) == (1, 2))
    }
}
