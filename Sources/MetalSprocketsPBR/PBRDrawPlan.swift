import GeometryLite3D
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
        var resources: [PBRMaterialResources]?
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
        var resources: [PBRMaterialResources]?
        var doubleSided: [Bool]
        /// Which records to draw (nil: all); a record whose node the pose hides is skipped.
        var visible: [Bool]?
    }

    /// Opaque batches drawn individually with one vertex variant's pipeline.
    struct OpaqueGroup: Identifiable {
        var variant: VertexVariant
        var batches: [PBRModel.Batch]
        var id: VertexVariant { variant }
    }

    var mergedStatic: MergedDraw?
    var mergedTransmissive: MergedDraw?
    var mergedSkinned: SkinnedMergedDraw?
    /// Non-empty groups, in ``VertexVariant/all`` order.
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
    init(model: PBRModel, pose: PBRPose?, stage: PBRRenderer.TransmissionPrePassStage, viewProjections: [simd_float4x4], cameraPosition: SIMD3<Float>, modelMatrix: simd_float4x4, usesMergedGeometry: Bool, materialOverrides: PBRModel.MaterialOverrides = [:], phase: PBRRenderer.DrawPhase = .all, transmissionAsCoverage: Bool = false) {
        var blendedOrder: [Int]?
        if case let .blended(order) = phase {
            blendedOrder = order
        }
        let drawsOpaque = blendedOrder == nil
        let drawsBlended = phase != .opaque
        // Frustum culling: batches whose (posed) bounds are entirely outside the view are not drawn.
        let frustums = viewProjections.map { Frustum(viewProjection: $0) }
        func worldBounds(_ batch: PBRModel.Batch) -> BoundingBox3D {
            (pose.map { model.worldBounds(of: batch, pose: $0) } ?? batch.worldBounds).transformedKeepingEmpty(by: modelMatrix)
        }
        func isTransmissive(_ batch: PBRModel.Batch) -> Bool {
            batch.material(overrides: materialOverrides).isTransmissive
        }
        func included(_ batch: PBRModel.Batch) -> Bool {
            let material = batch.material(overrides: materialOverrides)
            let inStage = switch stage {
            case .none: true
            case .opaque: !material.isTransmissive
            case .transmissiveBackFaces: material.isTransmissive && material.doubleSided
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
        opaqueGroups = VertexVariant.all.compactMap { variant in
            let batches = opaque.filter { VertexVariant($0) == variant }
            return batches.isEmpty ? nil : OpaqueGroup(variant: variant, batches: batches)
        }

        // Blended primitives keep one back-to-front order. Each vertex variant needs its own pipeline, so the order is
        // split into consecutive runs, each drawn with its own pipeline. With transmission as coverage, transmissive
        // opaque batches join the order (drawn by whichever renderer draws this model's opaque batches).
        let coverage = transmissionAsCoverage && drawsOpaque ? model.opaqueBatches.filter(isTransmissive).map { (batch: $0, premultiplied: true) } : []
        var candidates: [(batch: PBRModel.Batch, premultiplied: Bool)]
        if !drawsBlended {
            candidates = coverage
        } else if let blendedOrder {
            let byID = Dictionary(uniqueKeysWithValues: model.blendedBatches.map { ($0.id, $0) })
            candidates = blendedOrder.compactMap { byID[$0] }.map { ($0, false) }
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
        for (batch, premultiplied) in candidates where included(batch) {
            let variant = VertexVariant(batch)
            if let last = runs.last, last.variant == variant, last.premultiplied == premultiplied {
                runs[runs.count - 1].batches.append(batch)
            } else {
                runs.append(BlendedRun(id: runs.count, variant: variant, premultiplied: premultiplied, batches: [batch]))
            }
        }
        blendedRuns = runs
    }
}

/// Consecutive blended batches, in back-to-front order, that share a pipeline.
struct BlendedRun: Identifiable {
    var id: Int
    var variant: VertexVariant
    /// Transmissive opaque batches drawn as coverage: premultiplied color. Their batch IDs are opaque batch IDs, so
    /// they never share a run with blended batches.
    var premultiplied = false
    var batches: [PBRModel.Batch]
}

/// Which vertex shader a batch needs: skinned or instanced, with or without morph targets.
struct VertexVariant: Hashable, Identifiable {
    var skinned: Bool
    var morphed: Bool

    var id: Self { self }

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
