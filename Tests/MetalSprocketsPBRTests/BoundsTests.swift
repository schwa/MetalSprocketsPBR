import GeometryLite3D
@testable import MetalSprocketsPBR
import simd
import Testing

struct BoundsTests {
    @Test
    func transformingEmptyBoundsKeepsThemEmpty() {
        let matrix = simd_float4x4(diagonal: [2, 2, 2, 1])
        #expect(BoundingBox3D.empty.transformedKeepingEmpty(by: matrix) == .empty)
        let box = BoundingBox3D(min: [-1, -1, -1], max: [1, 1, 1])
        #expect(box.transformedKeepingEmpty(by: matrix) == BoundingBox3D(min: [-2, -2, -2], max: [2, 2, 2]))
    }

    @Test
    func frustumNeverSeesEmptyBounds() {
        let frustum = Frustum(viewProjection: simd_float4x4(diagonal: [1, 1, 0.5, 1]))
        #expect(!frustum.intersectsNonEmpty(.empty))
        #expect(frustum.intersectsNonEmpty(BoundingBox3D(min: [-0.5, -0.5, -0.5], max: [0.5, 0.5, 0.5])))
        #expect(!frustum.intersectsNonEmpty(BoundingBox3D(min: [5, 5, 0], max: [6, 6, 1])))
    }
}
