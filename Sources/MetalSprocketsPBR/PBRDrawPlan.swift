import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsPBRShaders
import simd

/// What ``PBRRenderer`` draws in one frame and how: which merged geometry sets (with posed instances, animated
/// materials and per-record visibility), which batches go through per-batch pipelines, and the back-to-front runs of
/// blended batches. Planning is pure; the renderer only turns a plan into elements.
struct PBRDrawPlan {
    /// A merged geometry set to draw with one element.
    struct MergedDraw {
        var geometry: PBRMergedGeometry
        /// Per-frame instances when posed; nil uses the rest-pose instance buffer.
        var instances: [PBRInstance]?
        /// Per-record uniforms when the pose animates materials or overrides apply; nil uses the prebuilt buffer.
        var materials: [PBRMaterialUniforms]?
        /// Per-record textures when overrides apply; nil uses the prebuilt buffer.
        var resources: ArgumentBuffer?
        /// Per-record double-sidedness of the material drawn.
        var doubleSided: [Bool]
        /// Which records to draw (frustum culling, and the back-face pre-pass's double-sided filter).
        var visible: [Bool]
        /// Draw only back faces, for the transmission pre-pass.
        var backFaces: Bool
    }

    /// Merged skinned geometry, with this frame's palette of every skin's joint matrices.
    struct SkinnedMergedDraw {
        var geometry: PBRMergedGeometry
        var palette: [simd_float4x4]
        var materials: [PBRMaterialUniforms]?
        var resources: ArgumentBuffer?
        var doubleSided: [Bool]
        /// Which records to draw (nil: all); a record whose node the pose hides is skipped.
        var visible: [Bool]?
    }

    /// Opaque batches drawn individually with one vertex variant's and render state's pipeline.
    struct OpaqueGroup: Identifiable {
        struct GroupID: Hashable {
            var variant: VertexVariant
            var state: PBRPipelineState
        }

        var variant: VertexVariant
        var state: PBRPipelineState
        var draws: [BatchDraw]
        var batches: [PBRModel.Batch] { draws.map(\.batch) }
        var id: GroupID { GroupID(variant: variant, state: state) }
    }

    /// Instances `start ..< start + count` of a batch's instance inputs, drawn with one winding.
    struct InstanceRange: Equatable {
        var start: Int
        var count: Int
        /// Front faces are clockwise: the instances' transform, combined with the model matrix, mirrors.
        var mirrored: Bool
    }

    /// One batch drawn by a per-batch pipeline: everything its draw binds and encodes this frame.
    struct BatchDraw: Identifiable {
        var batch: PBRModel.Batch
        var id: Int { batch.id }
        /// The batch's material, or its override.
        var material: PBRMaterial
        /// Animated and resolved for the primitive; points and lines are unlit.
        var uniforms: PBRMaterialUniforms
        var cullMode: MTLCullMode
        var fillMode: MTLTriangleFillMode
        /// Never empty.
        var ranges: [InstanceRange]
        /// Posed instances, unmirrored first, matching `ranges`; nil uses the batch's instance buffer.
        var instances: [PBRInstance]?
        /// This frame's joint matrices, for skinned batches.
        var jointMatrices: [simd_float4x4]?
        /// One weight per morph target (at least one), for batches with morph targets.
        var morphWeights: [Float]?
    }

    var mergedStatic: MergedDraw?
    var mergedTransmissive: MergedDraw?
    var mergedSkinned: SkinnedMergedDraw?
    /// Non-empty groups, in ``VertexVariant/all`` order, then by first use of each render state.
    var opaqueGroups: [OpaqueGroup]
    var blendedRuns: [BlendedRun]

    /// - Parameters:
    ///   - stage: Which transmission pre-pass stage (or the main pass) is being drawn.
    ///   - viewProjections: Every view's, for frustum culling (a batch is drawn if any view sees it), with `modelMatrix`
    ///     applied on top of placement.
    ///   - materialOverrides: Materials replacing primitives' own (see ``PBRModel/MaterialOverrides``).
    ///   - phase: Everything, only opaque batches, or only some blended batches in a given order.
    ///   - transmissionAsCoverage: Draw transmissive opaque batches blended (premultiplied), sorted with the blended
    ///     ones, instead of as opaque (see `PBRFrameUniforms.transmissionAsCoverage`).
    ///   - writesBlendedDepth: Blended batches write depth whatever their render state says (stereo).
    ///   - drawsTrianglesOnly: Leave out point and line batches (a rasterization rate map allows only triangles).
    init(model: PBRModel, pose: PBRPose?, stage: PBRRenderer.TransmissionPrePassStage, viewProjections: [simd_float4x4], cameraPosition: SIMD3<Float>, modelMatrix: simd_float4x4, usesMergedGeometry: Bool, materialOverrides: PBRModel.MaterialOverrides = [:], phase: PBRRenderer.DrawPhase = .all, transmissionAsCoverage: Bool = false, writesBlendedDepth: Bool = false, drawsTrianglesOnly: Bool = false) {
        var blendedOrder: [PBRRenderer.SortedBatch]?
        if case let .blended(order) = phase {
            blendedOrder = order
        }
        let drawsOpaque = blendedOrder == nil
        let drawsBlended = phase != .opaque
        // Frustum culling: batches whose (posed) bounds are entirely outside the view are not drawn.
        let frustums = viewProjections.map { Frustum(viewProjection: $0) }
        func worldBounds(_ batch: PBRModel.Batch) -> BoundingBox3D {
            model.worldBounds(of: batch, pose: pose, modelMatrix: modelMatrix)
        }
        func isTransmissive(_ batch: PBRModel.Batch) -> Bool {
            batch.material(overrides: materialOverrides).isTransmissive
        }
        func pipelineState(_ batch: PBRModel.Batch, coverage: Bool) -> PBRPipelineState {
            let material = batch.material(overrides: materialOverrides)
            var state = PBRPipelineState(material, writesBlendedDepth: writesBlendedDepth)
            if coverage {
                state.blendMode = .premultiplied
                state.depthWrite = writesBlendedDepth || material.renderState.depthWrite.resolved(blended: true)
            }
            return state
        }
        func included(_ batch: PBRModel.Batch) -> Bool {
            let material = batch.material(overrides: materialOverrides)
            let inStage = switch stage {
            case .none: true
            case .opaque: !material.isTransmissive
            case .transmissiveBackFaces: material.hasTransmissiveBackFaces
            }
            guard inStage else { return false }
            let bounds = worldBounds(batch)
            return frustums.contains { $0.intersectsNonEmpty(bounds) }
        }

        // Static opaque batches draw from merged buffers in one element. A pose gives per-frame instances and material
        // overrides. If the pose mirrors an instance away from its rest winding, that set draws per batch this frame.
        // Transmissive batches merge separately: the opaque pre-pass draws the rest, the back-face pre-pass draws the
        // transmissive set, and the main pass draws both.
        func mergedDraw(_ geometry: PBRMergedGeometry?, backFaces: Bool) -> MergedDraw? {
            guard drawsOpaque, usesMergedGeometry, let geometry else { return nil }
            var instances: [PBRInstance]?
            if let pose {
                guard let posed = geometry.instances(pose: pose) else { return nil }
                instances = posed
            }
            let doubleSided = geometry.records.map { geometry.material(of: $0, overrides: materialOverrides).doubleSided }
            // The back-face pre-pass only draws double-sided transmissive surfaces.
            let visible = zip(geometry.visibility(frustums: frustums, modelMatrix: modelMatrix, pose: pose), doubleSided).map { $0 && (!backFaces || $1) }
            return MergedDraw(geometry: geometry, instances: instances, materials: geometry.materials(pose: pose, overrides: materialOverrides), resources: geometry.resources(overrides: materialOverrides), doubleSided: doubleSided, visible: visible, backFaces: backFaces)
        }
        mergedStatic = stage == .transmissiveBackFaces ? nil : mergedDraw(model.merged, backFaces: false)
        // Transmission as coverage draws transmissive batches blended, so not from merged geometry.
        mergedTransmissive = stage == .opaque || transmissionAsCoverage ? nil : mergedDraw(model.mergedTransmissive, backFaces: stage == .transmissiveBackFaces)
        // Skinned opaque batches merged too; their joints come from one palette of every skin for this frame. Skinned
        // meshes need joint matrices even without an animation.
        if drawsOpaque, usesMergedGeometry, stage != .transmissiveBackFaces, let geometry = model.mergedSkinned {
            let skinPose = pose ?? model.restPose
            mergedSkinned = SkinnedMergedDraw(
                geometry: geometry,
                palette: geometry.jointPalette(skins: model.skins, pose: skinPose),
                materials: geometry.materials(pose: pose, overrides: materialOverrides),
                resources: geometry.resources(overrides: materialOverrides),
                doubleSided: geometry.records.map { geometry.material(of: $0, overrides: materialOverrides).doubleSided },
                visible: pose.flatMap { pose in pose.hidesNodes ? geometry.records.map { pose.isVisible($0.nodeIndices.first ?? -1) } : nil }
            )
        } else {
            mergedSkinned = nil
        }

        let mergedBatchIDs = [mergedStatic?.geometry, mergedTransmissive?.geometry, mergedSkinned?.geometry].reduce(into: Set<Int>()) { $0.formUnion($1?.batchIDs ?? []) }
        let opaque = drawsOpaque ? model.opaqueBatches.filter { included($0) && !mergedBatchIDs.contains($0.id) && !(transmissionAsCoverage && isTransmissive($0)) } : []
        let modelIsMirrored = modelMatrix.isMirroring
        func batchDraw(_ batch: PBRModel.Batch) -> BatchDraw? {
            Self.batchDraw(batch, model: model, pose: pose, stage: stage, modelIsMirrored: modelIsMirrored, materialOverrides: materialOverrides, drawsTrianglesOnly: drawsTrianglesOnly)
        }
        let opaqueDraws = opaque.compactMap(batchDraw)
        opaqueGroups = VertexVariant.all.flatMap { variant in
            var groups: [OpaqueGroup] = []
            for draw in opaqueDraws where VertexVariant(draw.batch) == variant {
                let state = pipelineState(draw.batch, coverage: false)
                if let index = groups.firstIndex(where: { $0.state == state }) {
                    groups[index].draws.append(draw)
                } else {
                    groups.append(OpaqueGroup(variant: variant, state: state, draws: [draw]))
                }
            }
            return groups
        }

        // Blended primitives keep one back-to-front order. Each vertex variant needs its own pipeline, so the order is
        // split into consecutive runs, each drawn with its own pipeline. With transmission as coverage, transmissive
        // opaque batches join the order. With several models they write depth, so they join the shared order of the
        // blended phase (see ``PBRScene/blendedOrder(_:cameraPosition:coverage:)``), after every model's opaque phase.
        let coverage = transmissionAsCoverage && phase == .all ? model.opaqueBatches.filter(isTransmissive).map { (batch: $0, premultiplied: true) } : []
        var candidates: [(batch: PBRModel.Batch, premultiplied: Bool)]
        if !drawsBlended {
            candidates = []
        } else if let blendedOrder {
            let blendedByID = Dictionary(uniqueKeysWithValues: model.blendedBatches.map { ($0.id, $0) })
            let opaqueByID = Dictionary(uniqueKeysWithValues: model.opaqueBatches.map { ($0.id, $0) })
            candidates = blendedOrder.compactMap { entry in
                (entry.coverage ? opaqueByID[entry.id] : blendedByID[entry.id]).map { ($0, entry.coverage) }
            }
        } else {
            candidates = model.blendedBatches.map { ($0, false) } + coverage
        }
        if blendedOrder == nil {
            let centers = candidates.map { worldBounds($0.batch).center }
            candidates = candidates.indices.sorted {
                simd_distance_squared(centers[$0], cameraPosition) > simd_distance_squared(centers[$1], cameraPosition)
            }.map { candidates[$0] }
        }
        var runs: [BlendedRun] = []
        let blendedDraws = candidates.filter { included($0.batch) }.compactMap { candidate in
            batchDraw(candidate.batch).map { (draw: $0, premultiplied: candidate.premultiplied) }
        }
        for (draw, premultiplied) in blendedDraws {
            let variant = VertexVariant(draw.batch)
            let state = pipelineState(draw.batch, coverage: premultiplied)
            if let last = runs.last, last.variant == variant, last.state == state, last.coverage == premultiplied {
                runs[runs.count - 1].draws.append(draw)
            } else {
                runs.append(BlendedRun(id: runs.count, variant: variant, state: state, coverage: premultiplied, draws: [draw]))
            }
        }
        blendedRuns = runs
    }

    /// How `batch` is drawn this frame, or nil when it draws nothing: a point or line batch that `drawsTrianglesOnly`
    /// leaves out, or every instance hidden.
    static func batchDraw(_ batch: PBRModel.Batch, model: PBRModel, pose: PBRPose?, stage: PBRRenderer.TransmissionPrePassStage, modelIsMirrored: Bool, materialOverrides: PBRModel.MaterialOverrides, drawsTrianglesOnly: Bool) -> BatchDraw? {
        let primitive = batch.primitive
        let isTriangles = primitive.primitiveType == .triangle
        guard isTriangles || !drawsTrianglesOnly else { return nil }
        let material = batch.material(overrides: materialOverrides)
        // KHR_animation_pointer can animate material properties; the pose carries the result.
        var uniforms = PBRMaterialUniforms.resolved(material, primitive: primitive, pose: pose)
        if !isTriangles {
            // Points and lines are drawn unlit in their base color, as three.js does.
            uniforms.unlit = 1
            uniforms.isPointOrLine = 1
        }
        let cullMode: MTLCullMode = !isTriangles ? .none : stage == .transmissiveBackFaces ? .front : material.doubleSided ? .none : .back
        let fillMode: MTLTriangleFillMode = material.renderState.fillMode == .lines ? .lines : .fill

        // Mirroring by both the node and the model matrix cancels out.
        var instances: [PBRInstance]?
        var jointMatrices: [simd_float4x4]?
        let ranges: [InstanceRange]
        if let skinIndex = batch.skinIndex {
            // Skinned meshes follow their joints, and need joint matrices even without an animation. Hidden skinned
            // meshes never get here: their bounds are empty, so the plan culls them.
            jointMatrices = model.skins[skinIndex].jointMatrices(for: pose ?? model.restPose)
            ranges = [InstanceRange(start: 0, count: batch.instanceCount, mirrored: batch.isMirrored != modelIsMirrored)]
        } else if let pose {
            // Hidden nodes' instances are left out. Posed instances are ordered unmirrored first, then mirrored (an
            // animation can mirror some of a batch's nodes), and drawn as up to two ranges with their own winding.
            let placements = zip(batch.nodeIndices, batch.instanceMatrices).filter { pose.isVisible($0.0) }.map { node, instanceMatrix in
                pose.placement(node: node, instanceMatrix: instanceMatrix)
            }
            guard !placements.isEmpty else { return nil }
            let unmirrored = placements.filter { !$0.isMirroring }
            let mirrored = placements.filter(\.isMirroring)
            instances = (unmirrored + mirrored).map { PBRInstance(worldMatrix: $0, normalMatrix: $0.inverse.transpose) }
            var posedRanges: [InstanceRange] = []
            if !unmirrored.isEmpty {
                posedRanges.append(InstanceRange(start: 0, count: unmirrored.count, mirrored: modelIsMirrored))
            }
            if !mirrored.isEmpty {
                posedRanges.append(InstanceRange(start: unmirrored.count, count: mirrored.count, mirrored: !modelIsMirrored))
            }
            ranges = posedRanges
        } else {
            ranges = [InstanceRange(start: 0, count: batch.instanceCount, mirrored: batch.isMirrored != modelIsMirrored)]
        }

        return BatchDraw(batch: batch, material: material, uniforms: uniforms, cullMode: cullMode, fillMode: fillMode, ranges: ranges, instances: instances, jointMatrices: jointMatrices, morphWeights: morphWeights(batch, model: model, pose: pose))
    }

    /// One weight per morph target from the pose, else the node's rest weights; nil without morph targets.
    static func morphWeights(_ batch: PBRModel.Batch, model: PBRModel, pose: PBRPose?) -> [Float]? {
        let targetCount = batch.primitive.morphTargetCount
        guard targetCount > 0 else { return nil }
        let node = batch.nodeIndices.first ?? 0
        let poseWeights = pose.flatMap { $0.morphWeights.indices.contains(node) ? $0.morphWeights[node] : nil }
        let weights = poseWeights ?? model.restMorphWeights(node: node)
        return (0 ..< targetCount).map { $0 < weights.count ? weights[$0] : 0 }
    }
}

/// Consecutive blended batches, in back-to-front order, that share a pipeline.
struct BlendedRun: Identifiable {
    var id: Int
    var variant: VertexVariant
    /// Transmissive opaque batches drawn as coverage blend premultiplied color.
    var state: PBRPipelineState
    /// Transmissive opaque batches. Their batch IDs are opaque batch IDs, so they never share a run with blended
    /// batches.
    var coverage: Bool
    var draws: [PBRDrawPlan.BatchDraw]
    var batches: [PBRModel.Batch] { draws.map(\.batch) }
}

/// Which vertex shader a batch needs: skinned or instanced, with or without morph targets.
struct VertexVariant: Hashable {
    var skinned: Bool
    var morphed: Bool

    static let all = [false, true].flatMap { skinned in [false, true].map { Self(skinned: skinned, morphed: $0) } }

    init(skinned: Bool, morphed: Bool) {
        self.skinned = skinned
        self.morphed = morphed
    }

    init(_ batch: PBRModel.Batch) {
        self.init(skinned: batch.skinIndex != nil, morphed: batch.primitive.morphTargetCount > 0)
    }

    var labelSuffix: String {
        (skinned ? " Skinned" : "") + (morphed ? " Morphed" : "")
    }
}
