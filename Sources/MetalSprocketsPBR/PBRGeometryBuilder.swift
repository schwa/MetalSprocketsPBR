import GeometryLite3D
import Metal
import MetalSprocketsPBRShaders
import MetalSupport
import simd
import SwiftMesh

/// Collects primitives' vertex data and places them all in one set of shared buffers (``PBRGeometryBuffers``), so
/// they can be drawn with few bindings and merged draws. Build once; the primitives can be used by several models.
public struct PBRGeometryBuilder {
    /// One primitive's data, packed in the renderer's vertex layout.
    struct PrimitiveData {
        var vertices: [PBRVertex]
        /// Relative to this primitive's vertices.
        var indices: [UInt32]
        /// `.triangle`, `.line` or `.point` (lists only).
        var primitiveType: MTLPrimitiveType
        /// Joints (indexes into the skin's joints) and weights, one per vertex, for skinned primitives.
        var skinVertices: [PBRSkinVertex]?
        /// Morph target offsets, [target][vertex].
        var morphTargets: [[PBRMorphDelta]]
        /// The morph targets as given, for the primitive's ``PBRModel/Primitive/mesh``.
        var morphTargetSource: MetalMesh.MorphTargets?
        var hasTangents: Bool
        var hasNormals: Bool
        var label: String?
    }

    public let device: MTLDevice
    private(set) var primitives: [PrimitiveData] = []

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Adds a primitive; returns its index in ``build()``'s result.
    ///
    /// `attributes` must include `.position` (`.float3`). Also used: `.normal` (`.float3`), `.tangent` (`.float4`, or
    /// `.float3` with w = 1), `.texcoord(0)` and `.texcoord(1)` (`.float2`), `.color(0)` (`.float4` or `.float3`), and
    /// `.jointIndices(0)` (`.ushort4` or `.float4`) with `.jointWeights(0)` (`.float4`). Missing ones get zero, or white
    /// for color. Others are ignored. `indices` must be a list (`.triangle`, `.line` or `.point`).
    @discardableResult
    public mutating func add(attributes: [MetalMesh.VertexAttributeData], indices: [UInt32], primitiveType: MTLPrimitiveType = .triangle, morphTargets: MetalMesh.MorphTargets? = nil, label: String? = nil) throws -> Int {
        primitives.append(try Self.pack(attributes: attributes, indices: indices, primitiveType: primitiveType, morphTargets: morphTargets, label: label))
        return primitives.count - 1
    }

    /// Adds each submesh of `mesh` as a primitive, with only the vertices it uses; returns their indices in
    /// ``build()``'s result. Attributes are read back from the mesh's vertex buffers, which must be CPU-visible; see
    /// ``add(attributes:indices:primitiveType:morphTargets:label:)`` for the ones used.
    @discardableResult
    public mutating func add(_ mesh: MetalMesh) throws -> [Int] {
        let attributes = mesh.vertexAttributeData()
        return try mesh.submeshes.enumerated().map { index, submesh in
            // Keep the vertices this submesh uses, in first-use order.
            var newIndices: [UInt32: UInt32] = [:]
            var sources: [Int] = []
            let indices = submesh.indices.map { index in
                if let existing = newIndices[index] {
                    return existing
                }
                let new = UInt32(sources.count)
                newIndices[index] = new
                sources.append(Int(index))
                return new
            }
            let subset = attributes.map { attribute in
                let size = attribute.format.size
                let bytes = sources.flatMap { attribute.bytes[$0 * size ..< ($0 + 1) * size] }
                return MetalMesh.VertexAttributeData(semantic: attribute.semantic, format: attribute.format, bytes: bytes, count: sources.count)
            }
            let morphTargets = mesh.morphTargets.map { morphTargets in
                MetalMesh.MorphTargets(
                    targets: morphTargets.targets.map { target in
                        MetalMesh.MorphTargets.Target(label: target.label, positionOffsets: target.positionOffsets.map { offsets in sources.map { offsets[$0] } }, normalOffsets: target.normalOffsets.map { offsets in sources.map { offsets[$0] } }, tangentOffsets: target.tangentOffsets.map { offsets in sources.map { offsets[$0] } })
                    },
                    defaultWeights: morphTargets.defaultWeights
                )
            }
            let label = submesh.label ?? mesh.label.map { mesh.submeshes.count > 1 ? "\($0)[\(index)]" : $0 }
            return try add(attributes: subset, indices: indices, primitiveType: submesh.primitiveType, morphTargets: morphTargets, label: label)
        }
    }

    static func pack(attributes: [MetalMesh.VertexAttributeData], indices: [UInt32], primitiveType: MTLPrimitiveType, morphTargets: MetalMesh.MorphTargets?, label: String?) throws -> PrimitiveData {
        func attribute(_ semantic: VertexDescriptor.Attribute.Semantic) -> MetalMesh.VertexAttributeData? {
            attributes.first { $0.semantic == semantic }
        }
        guard let positions = attribute(.position) else {
            throw PBRGeometryError.missingPositions
        }
        let vertexCount = positions.count
        for attribute in attributes where attribute.count != vertexCount {
            throw PBRGeometryError.attributeCountMismatch(attribute.semantic)
        }
        func read<T>(_ attribute: MetalMesh.VertexAttributeData, as _: T.Type) -> [T] {
            let size = attribute.format.size
            return attribute.bytes.withUnsafeBytes { bytes in
                (0 ..< attribute.count).map { bytes.loadUnaligned(fromByteOffset: $0 * size, as: T.self) }
            }
        }
        func floats<T>(_ semantic: VertexDescriptor.Attribute.Semantic, _ format: MTLVertexFormat, as _: T.Type) throws -> [T]? {
            guard let attribute = attribute(semantic) else { return nil }
            guard attribute.format == format else {
                throw PBRGeometryError.unsupportedAttributeFormat(semantic, attribute.format)
            }
            return read(attribute, as: T.self)
        }
        func float4s(_ semantic: VertexDescriptor.Attribute.Semantic, w: Float) throws -> [SIMD4<Float>]? {
            guard let attribute = attribute(semantic) else { return nil }
            switch attribute.format {
            case .float4:
                return read(attribute, as: SIMD4<Float>.self)

            case .float3:
                return read(attribute, as: Packed3<Float>.self).map { SIMD4($0.x, $0.y, $0.z, w) }

            default:
                throw PBRGeometryError.unsupportedAttributeFormat(semantic, attribute.format)
            }
        }

        let positionValues = try floats(.position, .float3, as: Packed3<Float>.self)!
        let normals = try floats(.normal, .float3, as: Packed3<Float>.self)
        let tangents = try float4s(.tangent, w: 1)
        let texCoords0 = try floats(.texcoord(0), .float2, as: SIMD2<Float>.self)
        let texCoords1 = try floats(.texcoord(1), .float2, as: SIMD2<Float>.self)
        let colors = try float4s(.color(0), w: 1)
        let vertices = (0 ..< vertexCount).map { index in
            var vertex = PBRVertex()
            vertex.position = SIMD3(positionValues[index])
            vertex.normal = normals.map { SIMD3($0[index]) } ?? .zero
            vertex.tangent = tangents?[index] ?? .zero
            vertex.texCoord0 = texCoords0?[index] ?? .zero
            vertex.texCoord1 = texCoords1?[index] ?? .zero
            vertex.color = colors?[index] ?? [1, 1, 1, 1]
            return vertex
        }

        var skinVertices: [PBRSkinVertex]?
        if let joints = attribute(.jointIndices(0)), let weights = try floats(.jointWeights(0), .float4, as: SIMD4<Float>.self) {
            let jointValues: [SIMD4<Float>]
            switch joints.format {
            case .ushort4:
                jointValues = read(joints, as: SIMD4<UInt16>.self).map { SIMD4<Float>($0) }

            case .float4:
                jointValues = read(joints, as: SIMD4<Float>.self)

            default:
                throw PBRGeometryError.unsupportedAttributeFormat(joints.semantic, joints.format)
            }
            skinVertices = zip(jointValues, weights).map { PBRSkinVertex(joints: $0, weights: $1) }
        }

        let morphDeltas = try (morphTargets?.targets ?? []).map { target in
            for offsets in [target.positionOffsets, target.normalOffsets, target.tangentOffsets] {
                if let offsets, offsets.count != vertexCount {
                    throw PBRGeometryError.morphTargetCountMismatch
                }
            }
            return (0 ..< vertexCount).map { index in
                PBRMorphDelta(position: target.positionOffsets?[index] ?? .zero, normal: target.normalOffsets?[index] ?? .zero, tangent: target.tangentOffsets?[index] ?? .zero)
            }
        }

        return PrimitiveData(
            vertices: vertices,
            indices: indices,
            primitiveType: primitiveType,
            skinVertices: skinVertices,
            morphTargets: morphDeltas,
            morphTargetSource: morphTargets?.targets.isEmpty == false ? morphTargets : nil,
            hasTangents: tangents != nil,
            hasNormals: normals != nil,
            label: label
        )
    }

    /// The primitives, in the order added, sharing one set of buffers. IDs are their indices.
    public func build() throws -> [PBRModel.Primitive] {
        let geometry = try PBRGeometryBuffers(primitives.map { PBRGeometryBuffers.Pending(vertices: $0.vertices, indices: $0.indices, skinVertices: $0.skinVertices) }, device: device)
        return try primitives.enumerated().map { id, data in
            let placement = geometry.placements[id]
            let (bounds, jointBounds) = Self.bounds(data)
            var morphBuffer: MTLBuffer?
            if !data.morphTargets.isEmpty {
                let packed = data.morphTargets.flatMap(\.self)
                guard let buffer = device.makeBuffer(bytes: packed, length: MemoryLayout<PBRMorphDelta>.stride * packed.count, options: .storageModeShared) else {
                    throw PBRGeometryError.bufferAllocationFailed
                }
                buffer.label = "\(data.label ?? "Primitive \(id)") Morph Targets"
                morphBuffer = buffer
            }
            return PBRModel.Primitive(
                id: id,
                geometry: geometry,
                mesh: Self.mesh(data, geometry: geometry, baseVertex: placement.baseVertex, indexStart: placement.indexStart, bounds: bounds),
                hasTangents: data.hasTangents,
                hasNormals: data.hasNormals,
                isSkinned: data.skinVertices != nil,
                morphBuffer: morphBuffer,
                morphTargetCount: data.morphTargets.count,
                jointBounds: jointBounds,
                bounds: bounds
            )
        }
    }

    /// A view of one primitive in the shared buffers.
    static func mesh(_ data: PrimitiveData, geometry: PBRGeometryBuffers, baseVertex: Int, indexStart: Int, bounds: PBRBounds) -> MetalMesh {
        var vertexBuffers: [Int: MTLBuffer] = [0: geometry.vertexBuffer]
        var vertexBufferOffsets = [0: baseVertex * MemoryLayout<PBRVertex>.stride]
        var vertexDescriptor = PBRModel.meshVertexDescriptor
        if data.skinVertices != nil, let skinBuffer = geometry.skinBuffer {
            vertexBuffers[PBRModel.skinBufferIndex] = skinBuffer
            vertexBufferOffsets[PBRModel.skinBufferIndex] = baseVertex * MemoryLayout<PBRSkinVertex>.stride
            vertexDescriptor = PBRModel.skinnedMeshVertexDescriptor
        }
        let boundingBox = data.vertices.isEmpty ? nil : BoundingBox(min: bounds.min, max: bounds.max)
        let submesh = MetalMesh.Submesh(
            label: data.label,
            indexBuffer: geometry.indexBuffer,
            indexBufferOffset: indexStart * MemoryLayout<UInt32>.stride,
            indexCount: data.indices.count,
            indexType: .uint32,
            primitiveType: data.primitiveType,
            bounds: boundingBox
        )
        var mesh = MetalMesh(vertexBuffers: vertexBuffers, vertexBufferOffsets: vertexBufferOffsets, vertexCount: data.vertices.count, vertexDescriptor: vertexDescriptor, submeshes: [submesh], label: data.label)
        mesh.bounds = boundingBox
        mesh.morphTargets = data.morphTargetSource
        return mesh
    }

    /// Mesh-space bounds grown to cover morph targets with weights in 0...1, and the bounds of the vertices each joint
    /// influences.
    static func bounds(_ data: PrimitiveData) -> (PBRBounds, [Int: PBRBounds]) {
        var bounds = PBRBounds.empty
        for vertex in data.vertices {
            bounds.min = simd_min(bounds.min, vertex.position)
            bounds.max = simd_max(bounds.max, vertex.position)
        }
        // Conservative growth from morph targets, assuming weights in 0...1.
        var morphGrowth = PBRBounds(min: .zero, max: .zero)
        for target in data.morphTargets where !target.isEmpty {
            let positions = target.map(\.position)
            morphGrowth.min += simd_min(positions.reduce(SIMD3(repeating: .infinity)) { simd_min($0, $1) }, .zero)
            morphGrowth.max += simd_max(positions.reduce(SIMD3(repeating: -.infinity)) { simd_max($0, $1) }, .zero)
        }
        bounds.min += morphGrowth.min
        bounds.max += morphGrowth.max

        var jointBounds: [Int: PBRBounds] = [:]
        if let skinVertices = data.skinVertices {
            for (vertex, skin) in zip(data.vertices, skinVertices) {
                for component in 0 ..< 4 where skin.weights[component] > 0 {
                    let joint = Int(skin.joints[component])
                    var box = jointBounds[joint] ?? .empty
                    box.min = simd_min(box.min, vertex.position + morphGrowth.min)
                    box.max = simd_max(box.max, vertex.position + morphGrowth.max)
                    jointBounds[joint] = box
                }
            }
        }
        return (bounds, jointBounds)
    }
}
