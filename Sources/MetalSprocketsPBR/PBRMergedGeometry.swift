import Metal
import MetalSprocketsPBRShaders
import simd

/// Opaque geometry merged into shared buffers, so one draw element can issue a Metal draw per primitive.
///
/// MetalSprockets' per-frame cost grows with the number of elements, not Metal draw calls. Merging lets opaque,
/// unmorphed triangle primitives share one vertex, index and instance buffer; each instance knows its draw record, and
/// the fragment shader looks up that record's material. One merge holds either static or skinned primitives; skinned
/// ones also share a skin-vertex buffer and read their joints from one per-frame palette of every skin.
public final class PBRMergedGeometry {
    public struct Record {
        public var indexStart: Int
        public var indexCount: Int
        public var baseVertex: Int
        public var firstInstance: Int
        public var instanceCount: Int
        public var doubleSided: Bool
        public var mirrored: Bool
        /// The node of each instance, and its placement relative to that node, for posing.
        public var nodeIndices: [Int]
        public var instanceMatrices: [simd_float4x4]
        public var material: PBRMaterial
        public var primitiveKey: PBRModel.Primitive.Key
        public var hasTangents: Bool
        public var hasNormals: Bool
        /// Mesh-space bounds of the primitive, and world bounds of all its instances at rest.
        public var localBounds: PBRBounds
        public var worldBounds: PBRBounds
        public var skinIndex: Int?
    }

    public let skinned: Bool
    public let records: [Record]
    /// IDs of the opaque batches drawn here instead of individually.
    public let batchIDs: Set<Int>
    /// The asset's shared vertex buffer; records find their primitives by base vertex.
    public let vertexBuffer: MTLBuffer
    /// The asset's shared 32-bit index buffer; records draw their own range.
    public let indexBuffer: MTLBuffer
    /// `PBRInstance` values for every record, in record order.
    public let instanceBuffer: MTLBuffer
    /// The record index of each instance.
    public let instanceRecordBuffer: MTLBuffer
    /// One `PBRMaterialUniforms` per record.
    public let materialBuffer: MTLBuffer
    /// One `PBRMaterialResources` per record.
    public let resourceBuffer: MTLBuffer
    /// Skinned only: the asset's shared `PBRSkinVertex` values, parallel to the vertices.
    public let skinVertexBuffer: MTLBuffer?
    /// Skinned only: each record's first joint in the palette.
    public let recordJointOffsetBuffer: MTLBuffer?
    /// Skinned only: the skins in palette order.
    public let paletteSkins: [Int]

    public var allocations: [any MTLAllocation] {
        [vertexBuffer, indexBuffer, instanceBuffer, instanceRecordBuffer, materialBuffer, resourceBuffer] + [skinVertexBuffer, recordJointOffsetBuffer].compactMap(\.self)
    }

    /// Static and skinned primitives merge separately, and so do transmissive ones (the transmission pre-pass must draw
    /// them apart from the rest). Skinned transmissive primitives are not merged.
    public static func canMerge(_ batch: PBRModel.Batch, skinned: Bool, transmissive: Bool) -> Bool {
        (batch.skinIndex != nil) == skinned && (!skinned || batch.primitive.isSkinned)
            && batch.primitive.morphTargetCount == 0 && batch.primitive.primitiveType == .triangle
            && batch.material.isTransmissive == transmissive && !(skinned && transmissive) && !batch.material.isBlended
    }

    /// Every palette skin's joint matrices for `pose`, in palette order.
    public func jointPalette(skins: [PBRModel.Skin], pose: PBRPose) -> [simd_float4x4] {
        paletteSkins.flatMap { skins[$0].jointMatrices(for: pose) }
    }

    /// Nil when fewer than two batches can be merged. Only batches whose primitives share the first mergeable one's
    /// geometry buffers are merged.
    public init?(batches: [PBRModel.Batch], skins: [PBRModel.Skin], skinned: Bool, transmissive: Bool = false, device: MTLDevice) throws {
        let candidates = batches.filter { Self.canMerge($0, skinned: skinned, transmissive: transmissive) }
        guard let geometry = candidates.first?.primitive.geometry else {
            return nil
        }
        let mergeable = candidates.filter { $0.primitive.geometry === geometry }
        guard mergeable.count >= 2 else {
            return nil
        }
        var jointOffsets: [UInt32] = []
        var skinOffsets: [Int: Int] = [:]
        var paletteSkins: [Int] = []
        var paletteSize = 0
        var instances: [PBRInstance] = []
        var instanceRecords: [UInt32] = []
        var materials: [PBRMaterialUniforms] = []
        var resources: [PBRMaterialResources] = []
        var records: [Record] = []
        for batch in mergeable {
            let primitive = batch.primitive
            // Every primitive of an asset shares one set of geometry buffers; nothing is copied.
            assert(primitive.geometry === geometry)
            if skinned, let skinIndex = batch.skinIndex {
                if skinOffsets[skinIndex] == nil {
                    skinOffsets[skinIndex] = paletteSize
                    paletteSkins.append(skinIndex)
                    paletteSize += skins[skinIndex].joints.count
                }
                jointOffsets.append(UInt32(skinOffsets[skinIndex]!))
            }

            let firstInstance = instances.count
            let instancePointer = batch.instanceBuffer.contents().bindMemory(to: PBRInstance.self, capacity: batch.instanceCount)
            instances.append(contentsOf: UnsafeBufferPointer(start: instancePointer, count: batch.instanceCount))
            instanceRecords.append(contentsOf: repeatElement(UInt32(records.count), count: batch.instanceCount))

            materials.append(.resolved(batch.material, primitive: primitive, pose: nil))
            resources.append(batch.material.resourceBuffer.contents().load(as: PBRMaterialResources.self))
            records.append(Record(indexStart: primitive.indexStart, indexCount: primitive.indexCount, baseVertex: primitive.baseVertex, firstInstance: firstInstance, instanceCount: batch.instanceCount, doubleSided: batch.material.doubleSided, mirrored: batch.isMirrored, nodeIndices: batch.nodeIndices, instanceMatrices: batch.instanceMatrices, material: batch.material, primitiveKey: primitive.key, hasTangents: primitive.hasTangents, hasNormals: primitive.hasNormals, localBounds: primitive.bounds, worldBounds: batch.worldBounds, skinIndex: batch.skinIndex))
        }

        func buffer<T>(_ values: [T], label: String) throws -> MTLBuffer {
            guard let buffer = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 1), options: .storageModeShared) }) else {
                throw PBRGeometryError.bufferAllocationFailed
            }
            buffer.label = label
            return buffer
        }
        // Labels name the kind of merge, so a GPU capture can tell the three merged geometries apart.
        let kind = skinned ? "Skinned" : transmissive ? "Transmissive" : "Static"
        vertexBuffer = geometry.vertexBuffer
        indexBuffer = geometry.indexBuffer
        instanceBuffer = try buffer(instances, label: "PBR Merged \(kind) Instances")
        instanceRecordBuffer = try buffer(instanceRecords, label: "PBR Merged \(kind) Instance Records")
        materialBuffer = try buffer(materials, label: "PBR Merged \(kind) Materials")
        resourceBuffer = try buffer(resources, label: "PBR Merged \(kind) Material Resources")
        skinVertexBuffer = skinned ? geometry.skinBuffer : nil
        recordJointOffsetBuffer = skinned ? try buffer(jointOffsets, label: "PBR Merged Skinned Joint Offsets") : nil
        self.paletteSkins = paletteSkins
        self.skinned = skinned
        self.records = records
        batchIDs = Set(mergeable.map(\.id))
    }

    /// Every instance placed by `pose`, in instance order, or nil when the pose mirrors an instance differently from
    /// its record's rest winding (the merged draw has one winding per record).
    public func instances(pose: PBRPose) -> [PBRInstance]? {
        var instances: [PBRInstance] = []
        instances.reserveCapacity(records.reduce(0) { $0 + $1.instanceCount })
        for record in records {
            for (node, instanceMatrix) in zip(record.nodeIndices, record.instanceMatrices) {
                // A record's instance count is fixed, so a hidden instance collapses to a point and draws nothing.
                guard pose.isVisible(node) else {
                    instances.append(PBRInstance(worldMatrix: simd_float4x4(), normalMatrix: simd_float4x4()))
                    continue
                }
                let world = pose.placement(node: node, instanceMatrix: instanceMatrix)
                guard world.isMirroring == record.mirrored else {
                    return nil
                }
                instances.append(PBRInstance(worldMatrix: world, normalMatrix: world.inverse.transpose))
            }
        }
        return instances
    }

    /// Whether each record has a visible instance inside any of `frustums`; `modelMatrix` is applied on top of world
    /// placement.
    public func visibility(frustums: [PBRFrustum], modelMatrix: simd_float4x4, pose: PBRPose?) -> [Bool] {
        records.map { record in
            let worldBounds = pose?.bounds(of: record.localBounds, nodes: record.nodeIndices, instanceMatrices: record.instanceMatrices) ?? record.worldBounds
            let bounds = worldBounds.transformed(by: modelMatrix)
            return frustums.contains { $0.intersects(bounds) }
        }
    }

    /// The material a record is drawn with: its override, or the one it was built with.
    public func material(of record: Record, overrides: PBRModel.MaterialOverrides) -> PBRMaterial {
        overrides.material(for: record.primitiveKey, default: record.material)
    }

    /// Whether any record is drawn with an override.
    public func isOverridden(by overrides: PBRModel.MaterialOverrides) -> Bool {
        !overrides.isEmpty && records.contains { overrides[$0.primitiveKey] != nil }
    }

    /// Each record's uniforms with `overrides` and `pose`'s animated materials applied, or nil when neither changes
    /// anything (the prebuilt material buffer is then used).
    public func materials(pose: PBRPose?, overrides: PBRModel.MaterialOverrides) -> [PBRMaterialUniforms]? {
        guard pose?.materialUniforms.isEmpty == false || isOverridden(by: overrides) else {
            return nil
        }
        return records.map { record in
            let material = material(of: record, overrides: overrides)
            return (pose?.uniforms(of: material) ?? material.uniforms).forPrimitive(hasTangents: record.hasTangents, hasNormals: record.hasNormals)
        }
    }

    /// Each record's textures with `overrides` applied, or nil when none applies (the prebuilt buffer is then used).
    public func resources(overrides: PBRModel.MaterialOverrides) -> [PBRMaterialResources]? {
        guard isOverridden(by: overrides) else {
            return nil
        }
        return records.map { material(of: $0, overrides: overrides).resourceBuffer.contents().load(as: PBRMaterialResources.self) }
    }
}
