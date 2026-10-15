import Metal
@testable import MetalSprocketsPBR
import MetalSprocketsPBRShaders
import simd
import SwiftMesh
import Testing

@Suite(.requiresMetal4)
struct GeometryBuilderTests {
    let device = MTLCreateSystemDefaultDevice()!
    let positions: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0]]

    @Test
    func addsEachSubmeshOfAMetalMesh() throws {
        var mesh = MetalMesh(mesh: .box(), device: device, label: "Box")
        mesh.morphTargets = MetalMesh.MorphTargets(targets: [.init(positionOffsets: Array(repeating: [0, 1, 0], count: mesh.vertexCount))], defaultWeights: [0.5])
        var builder = PBRGeometryBuilder(device: device)
        let indices = try builder.add(mesh)
        let primitives = try builder.build()
        #expect(indices == Array(0 ..< mesh.submeshes.count))
        #expect(primitives[0].morphTargetCount == 1)
        #expect(primitives[0].morphBuffer != nil)
        // Morphing can move vertices up by 1, so the bounds grow to cover it.
        #expect(primitives[0].bounds.max.y >= 1.5 - 1e-5)
    }

    @Test
    func readsFloat3TangentsAndColorsAndFloat4Joints() throws {
        var builder = PBRGeometryBuilder(device: device)
        try builder.add(attributes: [
            .positions(positions),
            .tangents([SIMD3<Float>](repeating: [1, 0, 0], count: 3)),
            .init(semantic: .color(0), format: .float3, values: [SIMD3<Float>](repeating: [1, 0, 0], count: 3)),
            .init(semantic: .jointIndices(0), format: .float4, values: [SIMD4<Float>](repeating: [1, 0, 0, 0], count: 3)),
            .jointWeights([SIMD4<Float>](repeating: [1, 0, 0, 0], count: 3))
        ], indices: [0, 1, 2])
        try builder.add(attributes: [
            .positions(positions),
            .tangents([SIMD4<Float>](repeating: [0, 1, 0, -1], count: 3)),
            .colors([SIMD4<Float>](repeating: [0, 1, 0, 1], count: 3)),
            .jointIndices([SIMD4<UInt16>](repeating: [2, 0, 0, 0], count: 3)),
            .jointWeights([SIMD4<Float>](repeating: [1, 0, 0, 0], count: 3))
        ], indices: [0, 1, 2])
        let data = builder.primitives
        #expect(data[0].vertices[0].tangent == [1, 0, 0, 1])
        #expect(data[0].vertices[0].color == [1, 0, 0, 1])
        #expect(data[0].skinVertices?[0].joints == [1, 0, 0, 0])
        #expect(data[1].vertices[0].tangent == [0, 1, 0, -1])
        #expect(data[1].skinVertices?[0].joints == [2, 0, 0, 0])
        let primitives = try builder.build()
        #expect(primitives[0].isSkinned)
        #expect(primitives[0].jointBounds[1] == primitives[0].bounds)
        #expect(primitives[1].jointBounds[2] == primitives[1].bounds)
    }

    @Test
    func rejectsBadAttributes() {
        var builder = PBRGeometryBuilder(device: device)
        #expect(throws: PBRGeometryError.self) {
            try builder.add(attributes: [.normals(positions)], indices: [0, 1, 2])
        }
        #expect(throws: PBRGeometryError.self) {
            try builder.add(attributes: [.positions(positions), .normals([[0, 0, 1]])], indices: [0, 1, 2])
        }
        #expect(throws: PBRGeometryError.self) {
            try builder.add(attributes: [.positions(positions), .init(semantic: .normal, format: .float4, values: [SIMD4<Float>](repeating: .zero, count: 3))], indices: [0, 1, 2])
        }
        #expect(throws: PBRGeometryError.self) {
            try builder.add(attributes: [.positions(positions), .init(semantic: .tangent, format: .float2, values: [SIMD2<Float>](repeating: .zero, count: 3))], indices: [0, 1, 2])
        }
        #expect(throws: PBRGeometryError.self) {
            try builder.add(attributes: [
                .positions(positions),
                .init(semantic: .jointIndices(0), format: .uchar4, values: [SIMD4<UInt8>](repeating: .zero, count: 3)),
                .jointWeights([SIMD4<Float>](repeating: [1, 0, 0, 0], count: 3))
            ], indices: [0, 1, 2])
        }
        #expect(throws: PBRGeometryError.self) {
            try builder.add(attributes: [.positions(positions)], indices: [0, 1, 2], morphTargets: .init(targets: [.init(positionOffsets: [.zero])]))
        }
    }
}
