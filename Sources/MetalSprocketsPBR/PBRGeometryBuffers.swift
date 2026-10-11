import Metal
import MetalSprocketsPBRShaders

/// Every primitive of an asset in one vertex buffer and one index buffer (and a skin buffer when any primitive is
/// skinned), so per-batch draws bind ranges of them and merged draws index into them directly, without copies.
public final class PBRGeometryBuffers: @unchecked Sendable {
    /// `PBRVertex` values.
    public let vertexBuffer: MTLBuffer
    /// 32-bit indices, each relative to its primitive's `baseVertex`.
    public let indexBuffer: MTLBuffer
    /// `PBRSkinVertex` values parallel to `vertexBuffer` (zero for unskinned primitives), or nil when nothing is skinned.
    public let skinBuffer: MTLBuffer?

    public var allocations: [any MTLAllocation] {
        [vertexBuffer, indexBuffer] + [skinBuffer].compactMap(\.self)
    }

    /// A primitive's data before it is placed in the shared buffers.
    public struct Pending {
        public var vertices: [PBRVertex]
        public var indices: [UInt32]
        public var skinVertices: [PBRSkinVertex]?

        public init(vertices: [PBRVertex], indices: [UInt32], skinVertices: [PBRSkinVertex]?) {
            self.vertices = vertices
            self.indices = indices
            self.skinVertices = skinVertices
        }
    }

    /// Where each pending primitive went: its base vertex and first index.
    public let placements: [(baseVertex: Int, indexStart: Int)]

    public init(_ pending: [Pending], device: MTLDevice) throws {
        var vertices: [PBRVertex] = []
        var indices: [UInt32] = []
        let anySkinned = pending.contains { $0.skinVertices != nil }
        var skinVertices: [PBRSkinVertex] = []
        var placements: [(baseVertex: Int, indexStart: Int)] = []
        vertices.reserveCapacity(pending.reduce(0) { $0 + $1.vertices.count })
        indices.reserveCapacity(pending.reduce(0) { $0 + $1.indices.count })
        for primitive in pending {
            placements.append((vertices.count, indices.count))
            vertices += primitive.vertices
            indices += primitive.indices
            if anySkinned {
                skinVertices += primitive.skinVertices ?? Array(repeating: PBRSkinVertex(), count: primitive.vertices.count)
            }
        }
        func buffer<T>(_ values: [T], label: String) throws -> MTLBuffer {
            let made = values.isEmpty
                ? device.makeBuffer(length: 1, options: .storageModeShared)
                : values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard let buffer = made else {
                throw PBRGeometryError.bufferAllocationFailed
            }
            buffer.label = label
            return buffer
        }
        vertexBuffer = try buffer(vertices, label: "PBR Vertices")
        indexBuffer = try buffer(indices, label: "PBR Indices")
        skinBuffer = anySkinned ? try buffer(skinVertices, label: "PBR Skin Vertices") : nil
        self.placements = placements
    }
}
