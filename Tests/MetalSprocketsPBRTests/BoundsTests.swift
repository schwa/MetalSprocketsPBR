import GeometryLite3D
@testable import MetalSprocketsPBR
import simd
import Testing

@Test
func transformingEmptyBoundsKeepsThemEmpty() {
    let matrix = simd_float4x4(diagonal: [2, 2, 2, 1])
    #expect(BoundingBox3D.empty.transformedKeepingEmpty(by: matrix) == .empty)
    let box = BoundingBox3D(min: [-1, -1, -1], max: [1, 1, 1])
    #expect(box.transformedKeepingEmpty(by: matrix) == BoundingBox3D(min: [-2, -2, -2], max: [2, 2, 2]))
}
