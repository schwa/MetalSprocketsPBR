import Metal
import MetalSprockets
import MetalSprocketsPBRShaders
import simd

/// Builds a ``PBRModel``: primitives (from ``PBRGeometryBuilder``) placed by nodes with materials, plus skins and
/// lights. ``build()`` sorts instances into opaque and blended, groups them into instanced batches, merges what can
/// share one draw element, and collects what must stay resident.
public struct PBRModelBuilder {
    public let device: MTLDevice
    /// Node transforms and morph weights at rest; instances without an explicit world matrix are placed by it.
    public var restPose: PBRPose
    public var skins: [PBRModel.Skin] = []
    public var lights: [PBRLight] = []
    /// Materials to keep resident even if no instance uses them (e.g. ones a pose may switch to).
    public var residentMaterials: [PBRMaterial] = []
    /// Primitives to keep resident even if no instance uses them.
    public var residentPrimitives: [PBRModel.Primitive] = []
    private var instances: [PBRModel.Instance] = []

    public init(device: MTLDevice, restPose: PBRPose) {
        self.device = device
        self.restPose = restPose
    }

    /// Places `primitive` with `material` by node `node` (an index into the pose's world matrices). `worldMatrix`
    /// defaults to the node's rest world matrix times `instanceMatrix`. Skinned primitives are placed by the joints of
    /// `skins[skin]` instead.
    public mutating func addInstance(_ primitive: PBRModel.Primitive, material: PBRMaterial, node: Int, instanceMatrix: simd_float4x4 = matrix_identity_float4x4, worldMatrix: simd_float4x4? = nil, skin: Int? = nil) {
        let world = worldMatrix ?? restPose.placement(node: node, instanceMatrix: instanceMatrix)
        var instance = PBRModel.Instance(id: instances.count, nodeIndex: node, skinIndex: primitive.isSkinned ? skin : nil, primitive: primitive, material: material, worldMatrix: world, normalMatrix: world.inverse.transpose, isMirrored: world.isMirroring, worldBounds: primitive.bounds.transformed(by: world))
        instance.instanceMatrix = instanceMatrix
        instances.append(instance)
    }

    public func build() throws -> PBRModel {
        // Skinned primitives are placed by their joints, not their node, so their bounds come from the rest pose.
        let placed = instances.map { instance in
            var instance = instance
            if let skinIndex = instance.skinIndex, skins.indices.contains(skinIndex) {
                instance.worldBounds = PBRModel.skinnedBounds(instance.primitive, skin: skins[skinIndex], pose: restPose)
            }
            return instance
        }
        let blended = placed.filter(\.material.isBlended)
        // Group by material so consecutive draws share bindings. Materials keep their first-use order and instances
        // their order within a material, so the same input always builds the same batches.
        var materialRanks: [ObjectIdentifier: Int] = [:]
        for instance in placed where materialRanks[ObjectIdentifier(instance.material)] == nil {
            materialRanks[ObjectIdentifier(instance.material)] = materialRanks.count
        }
        let opaque = placed.filter { !$0.material.isBlended }.sorted {
            (materialRanks[ObjectIdentifier($0.material)]!, $0.id) < (materialRanks[ObjectIdentifier($1.material)]!, $1.id)
        }
        let opaqueBatches = try Self.makeBatches(opaque, merging: true, device: device)
        let blendedBatches = try Self.makeBatches(blended, merging: false, device: device)
        let merged = try PBRMergedGeometry(batches: opaqueBatches, skins: skins, skinned: false, device: device)
        let mergedSkinned = try PBRMergedGeometry(batches: opaqueBatches, skins: skins, skinned: true, device: device)
        let mergedTransmissive = try PBRMergedGeometry(batches: opaqueBatches, skins: skins, skinned: false, transmissive: true, device: device)

        let resourceCollection = try ResourceCollection(device: device)
        let allocations = Self.residencyAllocations(
            materials: residentMaterials + placed.map(\.material),
            primitives: residentPrimitives + placed.map(\.primitive),
            batches: opaqueBatches + blendedBatches,
            merged: [merged, mergedSkinned, mergedTransmissive]
        )
        for allocation in allocations {
            try resourceCollection.register(allocation)
        }
        return PBRModel(
            opaqueInstances: opaque,
            blendedInstances: blended,
            opaqueBatches: opaqueBatches,
            blendedBatches: blendedBatches,
            skins: skins,
            lights: lights,
            restPose: restPose,
            // What is drawn at rest: instances the rest pose hides do not count.
            bounds: placed.filter { restPose.isVisible($0.nodeIndex) }.reduce(PBRBounds.empty) { $0.union($1.worldBounds) },
            resourceCollection: resourceCollection,
            merged: merged,
            mergedSkinned: mergedSkinned,
            mergedTransmissive: mergedTransmissive
        )
    }

    static func makeBatches(_ instances: [PBRModel.Instance], merging: Bool, device: MTLDevice) throws -> [PBRModel.Batch] {
        struct Key: Hashable {
            var geometry: ObjectIdentifier
            var primitive: Int
            var material: ObjectIdentifier
            var isMirrored: Bool
        }
        var groups: [[PBRModel.Instance]] = []
        if merging {
            var indices: [Key: Int] = [:]
            // Skinned and morphed instances have their own joints or weights, so they are never merged.
            func isUnique(_ instance: PBRModel.Instance) -> Bool {
                instance.skinIndex != nil || instance.primitive.morphTargetCount > 0
            }
            for instance in instances where isUnique(instance) {
                groups.append([instance])
            }
            for instance in instances where !isUnique(instance) {
                let key = Key(geometry: ObjectIdentifier(instance.primitive.geometry), primitive: instance.primitive.id, material: ObjectIdentifier(instance.material), isMirrored: instance.isMirrored)
                if let index = indices[key] {
                    groups[index].append(instance)
                } else {
                    indices[key] = groups.count
                    groups.append([instance])
                }
            }
        } else {
            groups = instances.map { [$0] }
        }
        return try groups.enumerated().map { index, group in
            let values = group.map { PBRInstance(worldMatrix: $0.worldMatrix, normalMatrix: $0.normalMatrix) }
            guard let buffer = device.makeBuffer(bytes: values, length: MemoryLayout<PBRInstance>.stride * values.count, options: .storageModeShared) else {
                throw PBRGeometryError.bufferAllocationFailed
            }
            buffer.label = "PBR Instances \(index)"
            let first = group[0]
            return PBRModel.Batch(
                id: index,
                primitive: first.primitive,
                material: first.material,
                isMirrored: first.isMirrored,
                skinIndex: first.skinIndex,
                instanceCount: group.count,
                nodeIndices: group.map(\.nodeIndex),
                instanceMatrices: group.map(\.instanceMatrix),
                instanceBuffer: buffer,
                worldBounds: group.dropFirst().reduce(first.worldBounds) { $0.union($1.worldBounds) }
            )
        }
    }

    /// Every long-lived allocation, each once: material textures and argument buffers, geometry, skin and morph
    /// buffers, batch instance buffers and merged geometry.
    static func residencyAllocations(materials: [PBRMaterial], primitives: [PBRModel.Primitive], batches: [PBRModel.Batch], merged: [PBRMergedGeometry?]) -> [any MTLAllocation] {
        var allocations: [any MTLAllocation] = []
        for material in materials {
            allocations.append(material.resourceBuffer)
            allocations += material.textureBindings.map(\.texture)
        }
        for primitive in primitives {
            allocations += primitive.geometry.allocations
            allocations += [primitive.morphBuffer].compactMap(\.self)
        }
        allocations += batches.map(\.instanceBuffer)
        allocations += merged.flatMap { $0?.allocations ?? [] }
        var seen = Set<ObjectIdentifier>()
        return allocations.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}
