import Metal
import MetalSprockets
import MetalSprocketsPBRShaders
import MetalSupport
import simd

/// Draws a ``PBRModel`` with the glTF metallic-roughness PBR model.
///
/// Place it inside a `RenderPass` with a depth attachment. Use one pipeline for opaque and masked primitives and one
/// for blended primitives, which are sorted back to front each frame.
public struct PBRRenderer: Element {
    public var model: PBRModel
    public var viewMatrix: simd_float4x4
    public var projectionMatrix: simd_float4x4
    public var modelMatrix: simd_float4x4
    public var lighting: PBRLighting
    /// Node transforms to draw with, e.g. from an animation. Nil draws the rest pose.
    public var pose: PBRPose?
    /// The opaque scene rendered by ``PBRTransmissionPass`` earlier in the frame. When set, transmissive materials
    /// show what is behind them; when nil they refract the environment instead.
    public var transmissionTarget: PBRTransmissionTarget?
    /// Set by ``PBRTransmissionPass``. Pre-pass stages write linear HDR radiance.
    var prePassStage: TransmissionPrePassStage = .none
    /// Output one shading input instead of the lit color, for debugging. Ignored by the transmission pre-pass.
    public var debugView: PBRDebugView = .lit
    /// Draw triangle edges over the output. Ignored by the transmission pre-pass.
    public var showsWireframe = false
    /// Materials to draw primitives with instead of their own, e.g. a material variant; switching needs no rebuild.
    public var materialOverrides: PBRModel.MaterialOverrides = [:]
    /// Draw these views at once (stereo, e.g. visionOS) instead of `viewMatrix` and `projectionMatrix`. The pipelines
    /// need a matching `maxVertexAmplificationCount` (``PBRImmersiveScene`` sets it). No transmission pre-pass then.
    public var stereo: PBRStereoViews?
    /// Skip point and line primitives: render passes with a rasterization rate map (visionOS foveation) only allow
    /// triangles, and Metal validation aborts on anything else.
    public var drawsTrianglesOnly = false

    /// The view-projection of every view drawn.
    var viewProjections: [simd_float4x4] { stereo?.viewProjections ?? [projectionMatrix * viewMatrix] }
    var cameraPositions: [SIMD3<Float>] { stereo?.cameraPositions ?? [viewMatrix.inverse.columns.3.xyz] }
    /// In stereo, transmissive surfaces draw as coverage: they blend over what is behind them (passthrough or the
    /// environment), so the room shows through glass. With a stereo transmission target, they also show the refracted
    /// model where the target alpha is not zero.
    var transmissionAsCoverage: Bool { stereo != nil && !isTransmissionPrePass }
    /// Whether blended surfaces write depth: in stereo (visionOS), where the compositor needs depth for every pixel we
    /// draw.
    var writesBlendedDepth: Bool { stereo != nil }
    /// Depth is reversed (near 1, far 0; see `simd_float4x4.perspective`), so nearer is greater.
    var depthFunction: MTLCompareFunction { .greater }
    /// Draw eligible batches from merged buffers. Tests turn it off to compare against per-batch drawing.
    var usesMergedGeometry = true
    /// Which part of the model to draw; ``PBRScene`` splits several models' drawing so blended batches of all of
    /// them can be sorted together.
    var phase: DrawPhase = .all
    var isTransmissionPrePass: Bool { prePassStage != .none }

    enum DrawPhase: Equatable {
        case all
        /// Opaque and masked batches only.
        case opaque
        /// Only these blended batches (by ID), in this order.
        case blended([Int])
    }

    enum TransmissionPrePassStage {
        case none
        /// Everything except transmissive primitives.
        case opaque
        /// Back faces of double-sided transmissive primitives, seeing the `opaque` stage's result (as three.js does).
        case transmissiveBackFaces
    }

    public init(model: PBRModel, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4 = matrix_identity_float4x4, lighting: PBRLighting? = nil, pose: PBRPose? = nil, transmissionTarget: PBRTransmissionTarget? = nil) {
        self.model = model
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.lighting = lighting ?? PBRLighting(lights: model.lights)
        // A model hiding nodes at rest (whose visibility animation can show them) is drawn with its rest pose, which
        // carries that visibility.
        self.pose = pose ?? (model.restPose.hidesNodes ? model.restPose : nil)
        self.transmissionTarget = transmissionTarget
    }

    public var body: some Element {
        get throws {
            try content()
        }
    }

    func content() throws -> some Element {
        let shaders = try PBRShaders.shared()
        let viewProjections = self.viewProjections
        let cameraPositions = self.cameraPositions
        var frame = PBRFrameUniforms()
        frame.cameraPositions = viewPair(cameraPositions)
        frame.exposure = lighting.exposure
        frame.toneMapping = lighting.toneMapping.shaderValue
        frame.environmentRotation = lighting.environmentRotationMatrix
        frame.lightCount = Int32(lighting.lights.count)
        let environment = lighting.environment
        frame.environmentIntensity = lighting.environmentIntensity
        frame.specularMipCount = Float(environment.specular.mipmapLevelCount)
        frame.viewProjectionMatrices = viewPair(viewProjections)
        frame.linearOutput = isTransmissionPrePass ? 1 : 0
        frame.debugView = (isTransmissionPrePass ? PBRDebugView.lit : debugView).shaderValue
        frame.showsWireframe = !isTransmissionPrePass && showsWireframe ? 1 : 0
        let transmissionScene: MTLTexture? = switch prePassStage {
        case .none: transmissionTarget?.color
        case .opaque: nil
        case .transmissiveBackFaces: try transmissionTarget?.backdrop()
        }
        frame.hasTransmissionScene = transmissionScene == nil ? 0 : 1
        frame.transmissionAsCoverage = transmissionAsCoverage ? 1 : 0
        frame.transmissionSceneMipCount = Float(transmissionScene?.mipmapLevelCount ?? 1)
        let bindings = FrameBindings(
            transmissionScene: transmissionScene ?? shaders.placeholderTexture,
            view: PBRViewUniforms(viewProjectionMatrices: viewPair(viewProjections), modelMatrix: modelMatrix, modelNormalMatrix: modelMatrix.inverse.transpose),
            frame: frame,
            // Shaders read through a pointer, so always bind at least one light.
            lights: lighting.lights.isEmpty ? [PBRLight()] : lighting.lights,
            irradiance: environment.irradiance,
            specular: environment.specular,
            brdfLookup: environment.brdfLookup,
            sampler: shaders.environmentSampler
        )

        // Blended batches are sorted from between the eyes.
        let plan = drawPlan(cameraPosition: cameraPositions.reduce(.zero, +) / Float(cameraPositions.count))
        // Skinned meshes need joint matrices even without an animation.
        let skinPose = pose ?? (model.skins.isEmpty ? nil : model.restPose)
        let context = PipelineContext(shaders: shaders, bindings: bindings, modelIsMirrored: modelMatrix.isMirroring, skinPose: skinPose)

        return try Group {
            if transmissionScene != nil {
                // Wait for PBRTransmissionPass to finish writing and mipmapping the scene texture.
                QueueBarrier(after: [.fragment, .blit], before: .fragment)
            }
            if let merged = plan.mergedStatic {
                try mergedPipeline(merged, context: context)
            }
            if let merged = plan.mergedTransmissive {
                try mergedPipeline(merged, context: context)
            }
            if let merged = plan.mergedSkinned {
                try skinnedMergedPipeline(merged, context: context)
            }
            ForEach(plan.opaqueGroups) { group in
                try pipeline("PBR Opaque\(group.variant.labelSuffix)", group.batches, variant: group.variant, blended: false, context: context)
            }
            ForEach(plan.blendedRuns) { run in
                try pipeline("PBR Blended\(run.variant.labelSuffix)\(run.premultiplied ? " Premultiplied" : "")", run.batches, variant: run.variant, blended: true, premultiplied: run.premultiplied, context: context)
            }
        }
        // Long-lived buffers and textures stay resident across frames, including the material textures that are only
        // reached through argument buffers.
        .useResourceCollection(model.resourceCollection)
    }

    private struct PipelineContext {
        var shaders: PBRShaders
        var bindings: FrameBindings
        var modelIsMirrored: Bool
        var skinPose: PBRPose?
    }

    @ElementBuilder
    private func pipeline(_ label: String, _ batches: [PBRModel.Batch], variant: VertexVariant, blended: Bool, premultiplied: Bool = false, context: PipelineContext) throws -> some Element {
        // Morphed and unmorphed draws are different element types; choosing per pipeline, not per draw, keeps the
        // per-draw tree small.
        if variant.morphed {
            try pipeline(label, batches, variant: variant, blended: blended, premultiplied: premultiplied, context: context) { batch in
                morphedDraw(batch, modelIsMirrored: context.modelIsMirrored, skinPose: context.skinPose)
            }
        } else {
            try pipeline(label, batches, variant: variant, blended: blended, premultiplied: premultiplied, context: context) { batch in
                draw(batch, modelIsMirrored: context.modelIsMirrored, skinPose: context.skinPose)
            }
        }
    }

    @ElementBuilder
    private func pipeline<Content: Element>(_ label: String, _ batches: [PBRModel.Batch], variant: VertexVariant, blended: Bool, premultiplied: Bool = false, context: PipelineContext, draw: @escaping (PBRModel.Batch) -> Content) throws -> some Element {
        let content = try RenderPipeline(label: label, vertexShader: context.shaders.vertexShader(variant), fragmentShader: context.shaders.fragment) {
            context.bindings.apply(to: ForEach(batches) { batch in
                draw(batch)
            })
        }
        .vertexDescriptor(variant.skinned ? PBRModel.skinnedVertexDescriptor : PBRModel.vertexDescriptor)
        if blended {
            content
                .renderPipelineDescriptorTransformer { descriptor in
                    let attachment = descriptor.colorAttachments[0]!
                    attachment.blendingState = .enabled
                    attachment.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                // visionOS shows our color only where depth is written. In stereo, blended surfaces write depth so
                // glass over passthrough stays visible. They draw back to front, so nearer ones still pass. Elsewhere
                // they leave depth alone.
                .depthCompare(function: depthFunction, enabled: writesBlendedDepth)
        } else {
            content.depthCompare(function: depthFunction, enabled: true)
        }
    }

    /// What this renderer draws this frame; see ``PBRDrawPlan``.
    func drawPlan(cameraPosition: SIMD3<Float>) -> PBRDrawPlan {
        PBRDrawPlan(model: model, pose: pose, stage: prePassStage, viewProjections: viewProjections, cameraPosition: cameraPosition, modelMatrix: modelMatrix, usesMergedGeometry: usesMergedGeometry, materialOverrides: materialOverrides, phase: phase, transmissionAsCoverage: transmissionAsCoverage)
    }

    /// One Metal draw per visible record of `merged`, all in one element.
    private func mergedDrawCalls(_ merged: PBRMergedGeometry, visible: [Bool]?, doubleSided: [Bool], backFaces: Bool, modelIsMirrored: Bool) -> some Element {
        let indexBuffer = merged.indexBuffer
        return Draw { encoder in
            stereo?.configure(encoder)
            for (index, record) in merged.records.enumerated() where visible?[index] ?? true {
                encoder.setCullMode(backFaces ? .front : doubleSided[index] ? .none : .back)
                // glTF front faces are counter-clockwise; a mirroring transform flips that.
                encoder.setFrontFacing(record.mirrored != modelIsMirrored ? .clockwise : .counterClockwise)
                encoder.drawIndexedPrimitives(
                    primitiveType: .triangle,
                    indexCount: record.indexCount,
                    indexType: .uint32,
                    indexBuffer: indexBuffer.gpuAddress + UInt64(record.indexStart * MemoryLayout<UInt32>.stride),
                    indexBufferLength: record.indexCount * MemoryLayout<UInt32>.stride,
                    instanceCount: record.instanceCount,
                    baseVertex: record.baseVertex,
                    baseInstance: record.firstInstance
                )
            }
        }
    }

    /// Every merged skinned record, drawn by one element. Not culled: skinned bounds move with the joints.
    private func skinnedMergedPipeline(_ plan: PBRDrawPlan.SkinnedMergedDraw, context: PipelineContext) throws -> some Element {
        let merged = plan.geometry
        let draw = mergedDrawCalls(merged, visible: plan.visible, doubleSided: plan.doubleSided, backFaces: false, modelIsMirrored: context.modelIsMirrored)
            .vertexBuffer(merged.skinVertexBuffer!, index: PBRModel.skinBufferIndex)
            .parameter("jointMatrices", values: plan.palette)
            .parameter("recordJointOffsets", buffer: merged.recordJointOffsetBuffer!)
        return try mergedPipeline("PBR Opaque Skinned Merged", vertexShader: context.shaders.skinnedMergedVertex, vertexDescriptor: PBRModel.skinnedVertexDescriptor, merged: merged, materials: plan.materials, resources: plan.resources, context: context) {
            draw
        }
    }

    /// Culled records skip their Metal draw, which adds no elements.
    private func mergedPipeline(_ plan: PBRDrawPlan.MergedDraw, context: PipelineContext) throws -> some Element {
        let merged = plan.geometry
        let draw = mergedDrawCalls(merged, visible: plan.visible, doubleSided: plan.doubleSided, backFaces: plan.backFaces, modelIsMirrored: context.modelIsMirrored)
            .parameter("instances", values: plan.instances, else: merged.instanceBuffer)
        return try mergedPipeline("PBR Opaque Merged", vertexShader: context.shaders.mergedVertex, vertexDescriptor: PBRModel.vertexDescriptor, merged: merged, materials: plan.materials, resources: plan.resources, context: context) {
            draw
        }
    }

    /// A merged pipeline: the record inputs every merged draw shares, its record materials and textures (prebuilt, or
    /// this frame's when given) and the frame's bindings, around `draw`.
    private func mergedPipeline(_ label: String, vertexShader: VertexShader, vertexDescriptor: MTLVertexDescriptor, merged: PBRMergedGeometry, materials: [PBRMaterialUniforms]?, resources: [PBRMaterialResources]?, context: PipelineContext, draw: () -> some Element) throws -> some Element {
        let content = draw()
            .vertexBuffer(merged.vertexBuffer, index: 0)
            .parameter("instanceRecords", buffer: merged.instanceRecordBuffer)
            .parameter("recordMaterials", values: materials, else: merged.materialBuffer)
            .parameter("recordResources", values: resources, else: merged.resourceBuffer)
        return try RenderPipeline(label: label, vertexShader: vertexShader, fragmentShader: context.shaders.mergedFragment) {
            context.bindings.apply(to: content)
        }
        .vertexDescriptor(vertexDescriptor)
        .depthCompare(function: depthFunction, enabled: true)
    }

    /// ``draw(_:modelIsMirrored:skinPose:)`` plus the morph target inputs, for batches with morph targets.
    func morphedDraw(_ batch: PBRModel.Batch, modelIsMirrored: Bool, skinPose: PBRPose?) -> some Element {
        let primitive = batch.primitive
        // Weights come from the pose, else the node's rest weights; shaders read one per target.
        let node = batch.nodeIndices.first ?? 0
        let poseWeights = pose.flatMap { $0.morphWeights.indices.contains(node) ? $0.morphWeights[node] : nil }
        let weights = poseWeights ?? model.restMorphWeights(node: node)
        let targetCount = primitive.morphTargetCount
        let morphWeights = (0 ..< max(targetCount, 1)).map { $0 < weights.count ? weights[$0] : 0 }
        let morph = PBRMorphUniforms(targetCount: UInt32(targetCount), vertexCount: UInt32(primitive.vertexCount))
        return draw(batch, modelIsMirrored: modelIsMirrored, skinPose: skinPose)
            .parameter("morph", value: morph)
            .parameter("morphDeltas", buffer: primitive.morphBuffer!)
            .parameter("morphWeights", values: morphWeights)
    }

    /// One instanced draw for every instance in `batch`.
    func draw(_ batch: PBRModel.Batch, modelIsMirrored: Bool, skinPose: PBRPose?) -> some Element {
        let primitive = batch.primitive
        let material = batch.material(overrides: materialOverrides)
        // The primitive's range of the model's shared buffers. Vertex buffers are bound at the primitive's first vertex
        // (baseVertex 0), so vertex_id stays local, as the per-primitive morph buffer expects.
        let geometry = primitive.geometry
        let indexBuffer = geometry.indexBuffer
        let indexCount = primitive.indexCount
        let indexOffset = UInt64(primitive.indexStart * MemoryLayout<UInt32>.stride)
        // Mirroring by both the node and the model matrix cancels out.
        // Posed instances are ordered unmirrored first, then mirrored (an animation can mirror some of a batch's
        // nodes), and drawn as up to two ranges with their own winding. Skinned meshes follow their joints instead.
        let posedNodes: [(node: Int, world: simd_float4x4)]?
        let ranges: [(start: Int, count: Int, mirrored: Bool)]
        if let pose, batch.skinIndex == nil {
            // Hidden nodes' instances are left out.
            let nodes = zip(batch.nodeIndices, batch.instanceMatrices).filter { pose.isVisible($0.0) }.map { node, instanceMatrix in
                (node: node, world: pose.placement(node: node, instanceMatrix: instanceMatrix))
            }
            let unmirrored = nodes.filter { !$0.world.isMirroring }
            let mirroredNodes = nodes.filter(\.world.isMirroring)
            // Every instance hidden: no draws, and the batch's own buffer is bound (an empty array cannot be).
            posedNodes = nodes.isEmpty ? nil : unmirrored + mirroredNodes
            ranges = [(0, unmirrored.count, modelIsMirrored), (unmirrored.count, mirroredNodes.count, !modelIsMirrored)].filter { $0.count > 0 } // swiftlint:disable:this empty_count (a tuple's count field)
        } else if let pose, let node = batch.nodeIndices.first, !pose.isVisible(node) {
            // A hidden skinned mesh.
            posedNodes = nil
            ranges = []
        } else {
            posedNodes = nil
            ranges = [(0, batch.instanceCount, batch.isMirrored != modelIsMirrored)]
        }

        // KHR_animation_pointer can animate material properties; the pose carries the result.
        var uniforms = PBRMaterialUniforms.resolved(material, primitive: primitive, pose: pose)
        let primitiveType = primitive.primitiveType
        let isTriangles = primitiveType == .triangle
        if !isTriangles {
            // Points and lines are drawn unlit in their base color, as three.js does.
            uniforms.unlit = 1
            uniforms.isPointOrLine = 1
        }
        let cullMode: MTLCullMode = !isTriangles ? .none : prePassStage == .transmissiveBackFaces ? .front : material.doubleSided ? .none : .back

        // A rasterization rate map (visionOS foveation) only allows triangles; point and line primitives are skipped.
        let skipsDraw = drawsTrianglesOnly && !isTriangles
        let draw = Draw { encoder in
            guard !skipsDraw else { return }
            stereo?.configure(encoder)
            encoder.setCullMode(cullMode)
            for range in ranges {
                // glTF front faces are counter-clockwise; a mirroring transform flips that.
                encoder.setFrontFacing(range.mirrored ? .clockwise : .counterClockwise)
                encoder.drawIndexedPrimitives(
                    primitiveType: primitiveType,
                    indexCount: indexCount,
                    indexType: .uint32,
                    indexBuffer: indexBuffer.gpuAddress + indexOffset,
                    indexBufferLength: indexCount * MemoryLayout<UInt32>.stride,
                    instanceCount: range.count,
                    baseVertex: 0,
                    baseInstance: range.start
                )
            }
        }
        // The index buffer is only referenced by address; the model's resource collection keeps it resident and the
        // model keeps it alive.
        .vertexBuffer(geometry.vertexBuffer, index: 0, offset: primitive.baseVertex * MemoryLayout<PBRVertex>.stride)

        return instances(of: batch, posedNodes: posedNodes, skinPose: skinPose, on: draw)
            .parameter("material", value: uniforms)
            // Every material texture and sampler, through one argument buffer. The textures it references are kept
            // resident by the model's resource collection.
            .parameter("materialResources", buffer: material.resourceBuffer)
    }
}

extension PBRRenderer {
    /// This renderer drawing only `phase`.
    func drawing(_ phase: DrawPhase) -> Self {
        var renderer = self
        renderer.phase = phase
        return renderer
    }

    /// This renderer drawing a transmission pre-pass stage.
    func prePass(_ stage: TransmissionPrePassStage) -> Self {
        var renderer = self
        renderer.prePassStage = stage
        return renderer
    }

    /// This renderer drawing `stereo`'s views.
    func viewing(_ stereo: PBRStereoViews?) -> Self {
        var renderer = self
        renderer.stereo = stereo
        return renderer
    }

    /// Draws `renderers` in order. The first is drawn directly: with one renderer the ForEach is empty, which costs
    /// less per frame than a ForEach of one or a conditional.
    @ElementBuilder
    static func all(_ renderers: [PBRRenderer]) -> some Element {
        renderers[0]
        ForEach(renderers.indices.dropFirst(), id: \.self) { index in
            renderers[index]
        }
    }

    /// Binds joint matrices for skinned batches; otherwise the rest-pose instance buffer or per-frame transforms from `pose`.
    @ElementBuilder
    func instances(of batch: PBRModel.Batch, posedNodes: [(node: Int, world: simd_float4x4)]?, skinPose: PBRPose?, on content: some Element) -> some Element {
        if let skinIndex = batch.skinIndex, let skinBuffer = batch.primitive.geometry.skinBuffer, let skinPose {
            content
                .vertexBuffer(skinBuffer, index: PBRModel.skinBufferIndex, offset: batch.primitive.baseVertex * MemoryLayout<PBRSkinVertex>.stride)
                .parameter("jointMatrices", values: model.skins[skinIndex].jointMatrices(for: skinPose))
        } else if let posedNodes {
            content.parameter("instances", values: posedNodes.map { PBRInstance(worldMatrix: $0.world, normalMatrix: $0.world.inverse.transpose) })
        } else {
            content.parameter("instances", buffer: batch.instanceBuffer)
        }
    }
}

extension Element {
    /// Binds `values` when given (this frame's), else `buffer` (prebuilt).
    @ElementBuilder
    func parameter<Value>(_ name: String, values: [Value]?, else buffer: MTLBuffer) -> some Element {
        if let values {
            parameter(name, values: values)
        } else {
            parameter(name, buffer: buffer)
        }
    }
}

/// Per-frame shader inputs shared by every draw in a pipeline.
private struct FrameBindings {
    var transmissionScene: MTLTexture
    var view: PBRViewUniforms
    var frame: PBRFrameUniforms
    var lights: [PBRLight]
    var irradiance: MTLTexture
    var specular: MTLTexture
    var brdfLookup: MTLTexture
    var sampler: MTLSamplerState

    func apply(to content: some Element) -> some Element {
        content
            .parameter("view", value: view)
            .parameter("frame", value: frame)
            .parameter("lights", values: lights)
            .parameter("environmentIrradiance", texture: irradiance)
            .parameter("environmentSpecular", texture: specular)
            .parameter("brdfLookup", texture: brdfLookup)
            .parameter("environmentSampler", samplerState: sampler)
            .parameter("transmissionScene", texture: transmissionScene)
    }
}

struct PBRShaders {
    var vertex: VertexShader
    var fragment: FragmentShader
    var skinnedVertex: VertexShader
    var morphedVertex: VertexShader
    var mergedVertex: VertexShader
    var skinnedMergedVertex: VertexShader
    var mergedFragment: FragmentShader
    var skinnedMorphedVertex: VertexShader
    var backgroundVertex: VertexShader
    var backgroundFragment: FragmentShader
    var copyFragment: FragmentShader
    /// Bound as the transmission scene when there is none; never sampled then.
    var placeholderTexture: MTLTexture
    var environmentSampler: MTLSamplerState

    // A static let is initialized once, thread-safely. Renderers are built on several threads. Immutable after creation.
    nonisolated(unsafe) private static let cached = Result { try make() }

    static func shared() throws -> Self {
        try cached.get()
    }

    func vertexShader(_ variant: VertexVariant) -> VertexShader {
        switch (variant.skinned, variant.morphed) {
        case (false, false): vertex
        case (false, true): morphedVertex
        case (true, false): skinnedVertex
        case (true, true): skinnedMorphedVertex
        }
    }

    private static func make() throws -> Self {
        let device = _MTLCreateSystemDefaultDevice()
        let library = try ShaderLibrary(bundle: .metalSprocketsPBRShaders())
        let pbr = library.namespaced("PBR")
        let ibl = library.namespaced("PBRIBL")

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.supportArgumentBuffers = true
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let placeholderTexture = device.makeTexture(descriptor: {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
                // An array, like PBRTransmissionTarget's textures.
                descriptor.textureType = .type2DArray
                descriptor.usage = .shaderRead
                return descriptor
              }())
        else {
            throw PBREnvironmentError.resourceCreationFailed("renderer resources")
        }

        return Self(
            vertex: try pbr.vertex_main,
            fragment: try pbr.fragment_main,
            skinnedVertex: try pbr.vertex_skinned,
            morphedVertex: try pbr.vertex_main_morphed,
            mergedVertex: try pbr.vertex_merged,
            skinnedMergedVertex: try pbr.vertex_skinned_merged,
            mergedFragment: try pbr.fragment_merged,
            skinnedMorphedVertex: try pbr.vertex_skinned_morphed,
            backgroundVertex: try ibl.background_vertex,
            backgroundFragment: try ibl.background_fragment,
            copyFragment: try ibl.copy_fragment,
            placeholderTexture: placeholderTexture,
            environmentSampler: sampler
        )
    }
}
