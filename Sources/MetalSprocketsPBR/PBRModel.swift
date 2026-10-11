import Metal
import MetalSprockets
import MetalSprocketsPBRShaders
import MetalSupport
import simd
import SwiftMesh

/// GPU-ready content for the PBR renderer: primitives placed by nodes, with materials, skins and lights. Build one
/// with ``PBRModelBuilder``; draw it with a ``PBRPose`` for each frame.
///
/// Immutable, so it can be built on a background task and handed to the render thread. Primitives, materials and
/// textures may be shared with other models.
public final class PBRModel: @unchecked Sendable {
    public struct Primitive {
        /// Unique among primitives built together; primitives sharing it share geometry.
        public var id: Int
        /// The shared buffers holding this primitive at `baseVertex` and `indexStart`.
        public var geometry: PBRGeometryBuffers
        /// This primitive's slice of `geometry`, with one submesh. Its buffers are `geometry`'s, not copies.
        public var mesh: MetalMesh
        /// First vertex in `geometry.vertexBuffer` (and `skinBuffer`); indices are relative to it.
        public var baseVertex: Int { (mesh.vertexBufferOffsets[0] ?? 0) / MemoryLayout<PBRVertex>.stride }
        public var vertexCount: Int { mesh.vertexCount }
        /// First index in `geometry.indexBuffer` (32-bit).
        public var indexStart: Int { mesh.submeshes[0].indexBufferOffset / MemoryLayout<UInt32>.stride }
        public var indexCount: Int { mesh.submeshes[0].indexCount }
        /// `.triangle`, `.line` or `.point`; points and lines are drawn unlit.
        public var primitiveType: MTLPrimitiveType { mesh.submeshes[0].primitiveType }
        public var hasTangents: Bool
        /// False without vertex normals; the shader then derives flat normals per pixel.
        public var hasNormals: Bool = true
        /// Whether the primitive has joints and weights, stored in `geometry.skinBuffer`.
        public var isSkinned: Bool
        /// `PBRMorphDelta` values, [target][vertex], for primitives with morph targets.
        public var morphBuffer: MTLBuffer?
        public var morphTargetCount: Int
        /// Mesh-space bounds of the vertices influenced by each joint (keyed by index into the skin's joints).
        public var jointBounds: [Int: PBRBounds]
        /// Mesh-space bounds, grown to cover morph targets with weights in 0...1.
        public var bounds: PBRBounds

        /// Identifies a primitive across models: its geometry buffers and its ID in them.
        public struct Key: Hashable, Sendable {
            public var geometry: ObjectIdentifier
            public var id: Int
        }

        public var key: Key { Key(geometry: ObjectIdentifier(geometry), id: id) }
    }

    /// Replacement materials for primitives, keyed by primitive, such as a material variant. An override must keep its
    /// primitive's pass: the same alpha mode and transmission (``PBRMaterial/canOverride(_:)``). Textures, factors, and
    /// double-sidedness can change.
    public typealias MaterialOverrides = [Primitive.Key: PBRMaterial]

    /// The joint nodes of a skin and their inverse bind matrices.
    public struct Skin: Sendable {
        public var joints: [Int]
        public var inverseBindMatrices: [simd_float4x4]

        public init(joints: [Int], inverseBindMatrices: [simd_float4x4]) {
            self.joints = joints
            self.inverseBindMatrices = inverseBindMatrices
        }

        /// One matrix per joint for `pose`: the joint's world matrix times its inverse bind matrix.
        public func jointMatrices(for pose: PBRPose) -> [simd_float4x4] {
            zip(joints, inverseBindMatrices).map { joint, inverseBind in
                pose.worldMatrix(ofNode: joint) * inverseBind
            }
        }
    }

    /// A primitive placed by a node.
    public struct Instance: Identifiable {
        public var id: Int
        /// The node that places this primitive; indexes ``PBRPose/worldMatrices``.
        public var nodeIndex: Int
        /// Placement relative to the node: identity, or one copy's transform when a node draws several.
        public var instanceMatrix: simd_float4x4 = matrix_identity_float4x4
        /// Index into ``PBRModel/skins`` when the primitive is skinned.
        public var skinIndex: Int?
        public var primitive: Primitive
        public var material: PBRMaterial
        public var worldMatrix: simd_float4x4
        public var normalMatrix: simd_float4x4
        public var isMirrored: Bool
        public var worldBounds: PBRBounds
    }

    /// Instances drawn with one instanced draw call: same primitive, material and winding.
    public struct Batch: Identifiable {
        public var id: Int
        public var primitive: Primitive
        public var material: PBRMaterial
        public var isMirrored: Bool
        /// Skinned batches hold one instance and are drawn with the skinned pipeline.
        public var skinIndex: Int?
        public var instanceCount: Int
        /// The node of each instance, in instance order.
        public var nodeIndices: [Int]
        /// Each instance's placement relative to its node (see ``Instance/instanceMatrix``), in instance order.
        public var instanceMatrices: [simd_float4x4]
        /// `instanceCount` packed `PBRInstance` values for the rest pose.
        public var instanceBuffer: MTLBuffer
        public var worldBounds: PBRBounds
    }

    public let opaqueInstances: [Instance]
    public let blendedInstances: [Instance]
    /// Opaque and masked instances grouped for instanced drawing.
    public let opaqueBatches: [Batch]
    /// One batch per blended instance, so they can be sorted back to front.
    public let blendedBatches: [Batch]
    public let skins: [Skin]
    /// Lights at rest.
    public let lights: [PBRLight]
    /// Node transforms and morph weights at rest; drawn when no pose is given.
    public let restPose: PBRPose
    /// Of every instance at rest, with skinned instances placed by their joints.
    public let bounds: PBRBounds
    /// Every long-lived GPU allocation the model draws with (geometry, instance data, textures, material argument
    /// buffers), kept resident across frames. Material textures are only reached through argument buffers, so they
    /// must be resident. The renderer attaches it.
    public let resourceCollection: ResourceCollection
    /// Static opaque batches merged for drawing with one element; nil when there is nothing worth merging.
    public let merged: PBRMergedGeometry?
    /// Skinned opaque batches merged the same way, reading joints from one per-frame palette.
    public let mergedSkinned: PBRMergedGeometry?
    /// Static transmissive opaque batches, merged apart from the rest for the transmission pre-pass.
    public let mergedTransmissive: PBRMergedGeometry?

    /// Whether any material uses transmission, i.e. whether a transmission pass is worth running.
    public var hasTransmission: Bool {
        (opaqueBatches + blendedBatches).contains { $0.material.uniforms.transmissionFactor > 0 }
    }

    public init(opaqueInstances: [Instance], blendedInstances: [Instance], opaqueBatches: [Batch], blendedBatches: [Batch], skins: [Skin], lights: [PBRLight], restPose: PBRPose, bounds: PBRBounds, resourceCollection: ResourceCollection, merged: PBRMergedGeometry?, mergedSkinned: PBRMergedGeometry?, mergedTransmissive: PBRMergedGeometry?) {
        self.opaqueInstances = opaqueInstances
        self.blendedInstances = blendedInstances
        self.opaqueBatches = opaqueBatches
        self.blendedBatches = blendedBatches
        self.skins = skins
        self.lights = lights
        self.restPose = restPose
        self.bounds = bounds
        self.resourceCollection = resourceCollection
        self.merged = merged
        self.mergedSkinned = mergedSkinned
        self.mergedTransmissive = mergedTransmissive
    }

    /// Vertex buffer index of skinning data. Vertex buffers share the table with `[[buffer(n)]]` arguments, and the
    /// skinned vertex shader uses 1...3, so this must stay clear of them.
    public static let skinBufferIndex = 4

    /// `PBRVertex` in vertex buffer 0. Attribute indices match `VertexIn` in PBR.metal.
    public static let meshVertexDescriptor: VertexDescriptor = {
        let fields: [(VertexDescriptor.Attribute.Semantic, MTLVertexFormat, Int?)] = [
            (.position, .float3, MemoryLayout<PBRVertex>.offset(of: \.position)),
            (.normal, .float3, MemoryLayout<PBRVertex>.offset(of: \.normal)),
            (.tangent, .float4, MemoryLayout<PBRVertex>.offset(of: \.tangent)),
            (.texcoord(0), .float2, MemoryLayout<PBRVertex>.offset(of: \.texCoord0)),
            (.texcoord(1), .float2, MemoryLayout<PBRVertex>.offset(of: \.texCoord1)),
            (.color(0), .float4, MemoryLayout<PBRVertex>.offset(of: \.color)),
        ]
        return VertexDescriptor(
            attributes: fields.map { .init(semantic: $0.0, format: $0.1, offset: $0.2!, bufferIndex: 0) },
            layouts: [.init(bufferIndex: 0, stride: MemoryLayout<PBRVertex>.stride, stepFunction: .perVertex, stepRate: 1)]
        )
    }()

    /// ``meshVertexDescriptor`` plus joints and weights (`PBRSkinVertex`) from vertex buffer ``skinBufferIndex``.
    public static let skinnedMeshVertexDescriptor: VertexDescriptor = {
        var descriptor = meshVertexDescriptor
        descriptor.attributes += [
            .init(semantic: .jointIndices(0), format: .float4, offset: MemoryLayout<PBRSkinVertex>.offset(of: \.joints)!, bufferIndex: skinBufferIndex),
            .init(semantic: .jointWeights(0), format: .float4, offset: MemoryLayout<PBRSkinVertex>.offset(of: \.weights)!, bufferIndex: skinBufferIndex),
        ]
        descriptor.layouts[skinBufferIndex] = .init(bufferIndex: skinBufferIndex, stride: MemoryLayout<PBRSkinVertex>.stride, stepFunction: .perVertex, stepRate: 1)
        return descriptor
    }()

    // Never mutated after creation.
    nonisolated(unsafe) public static let vertexDescriptor = MTLVertexDescriptor(meshVertexDescriptor)

    /// ``vertexDescriptor`` plus joints and weights from vertex buffer ``skinBufferIndex``.
    nonisolated(unsafe) public static let skinnedVertexDescriptor = MTLVertexDescriptor(skinnedMeshVertexDescriptor)
}

public extension PBRModel {
    /// World bounds of everything drawn with `pose`.
    func bounds(for pose: PBRPose) -> PBRBounds {
        (opaqueBatches + blendedBatches).reduce(PBRBounds.empty) { $0.union(worldBounds(of: $1, pose: pose)) }
    }

    /// World bounds of a batch's instances drawn with `pose`; hidden instances do not count.
    func worldBounds(of batch: Batch, pose: PBRPose) -> PBRBounds {
        if let skinIndex = batch.skinIndex, skins.indices.contains(skinIndex) {
            guard pose.isVisible(batch.nodeIndices.first ?? -1) else { return .empty }
            return Self.skinnedBounds(batch.primitive, skin: skins[skinIndex], pose: pose)
        }
        return pose.bounds(of: batch.primitive.bounds, nodes: batch.nodeIndices, instanceMatrices: batch.instanceMatrices)
    }

    /// Morph weights for `node` at rest.
    func restMorphWeights(node: Int) -> [Float] {
        restPose.morphWeights.indices.contains(node) ? restPose.morphWeights[node] : []
    }

    /// Union of each joint's influenced vertices moved by that joint. Conservative: a vertex blended between joints
    /// lies between their positions, which the union covers.
    static func skinnedBounds(_ primitive: Primitive, skin: Skin, pose: PBRPose) -> PBRBounds {
        let jointMatrices = skin.jointMatrices(for: pose)
        return primitive.jointBounds.reduce(PBRBounds.empty) { result, entry in
            guard jointMatrices.indices.contains(entry.key) else { return result }
            return result.union(entry.value.transformed(by: jointMatrices[entry.key]))
        }
    }
}
