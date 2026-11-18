import Foundation
import GeometryLite3D
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
    public var stereo: StereoViews?
    /// Skip point and line primitives: render passes with a rasterization rate map (visionOS foveation) only allow
    /// triangles, and Metal validation aborts on anything else.
    public var drawsTrianglesOnly = false

    var views: PBRViews { PBRViews(viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, stereo: stereo) }
    /// The view-projection of every view drawn.
    var viewProjections: [simd_float4x4] { views.viewProjections }
    /// In stereo, transmissive surfaces draw as coverage: they blend over what is behind them (passthrough or the
    /// environment), so the room shows through glass. With a stereo transmission target, they also show the refracted
    /// model where the target alpha is not zero.
    var transmissionAsCoverage: Bool { views.isStereo && !isTransmissionPrePass }
    /// Whether blended surfaces write depth: in stereo (visionOS), where the compositor needs depth for every pixel we
    /// draw.
    var writesBlendedDepth: Bool { views.isStereo }
    /// Screen-space occlusion is one texture for one view, so stereo and the pre-pass's own target draw without it.
    var usesAmbientOcclusion: Bool { !views.isStereo && !isTransmissionPrePass }
    /// Depth is reversed (near 1, far 0), so nearer is greater.
    var depthFunction: MTLCompareFunction { .greater }
    /// Draw eligible batches from merged buffers. Tests turn it off to compare against per-batch drawing.
    var usesMergedGeometry = true
    /// Which part of the model to draw; ``PBRScene`` splits several models' drawing so blended batches of all of
    /// them can be sorted together.
    var phase: DrawPhase = .all
    var isTransmissionPrePass: Bool { prePassStage != .none }
    /// The frame's lighting and view bindings, built once and shared by renderers of one frame (see
    /// ``sharingFrameBindings(_:)``). Nil builds them in `content()`. Cleared when the views or pre-pass stage change.
    var frameBindings: PBRFrameBindings?

    enum DrawPhase: Equatable {
        case all
        /// Opaque and masked batches only, without transmissive ones drawn as coverage.
        case opaque
        /// Only these batches, in this order.
        case blended([SortedBatch])
    }

    /// A batch in a back-to-front order: a blended batch, or a transmissive opaque one drawn as coverage. Batch IDs
    /// are unique only among a model's opaque or blended batches.
    struct SortedBatch: Hashable {
        var id: Int
        var coverage: Bool
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
        let device = model.device
        precondition(lighting.environment.source.device === device, "The model and the lighting environment must be on one device")
        let shaders = try PBRShaders.shared(device: device)
        let views = views
        let viewProjections = views.viewProjections
        let transmissionScene: MTLTexture? = switch prePassStage {
        case .none: transmissionTarget?.color
        case .opaque: nil
        case .transmissiveBackFaces: try transmissionTarget?.backdrop()
        }
        var bindings = try frameBindings ?? makeFrameBindings()
        bindings.frame.linearOutput = isTransmissionPrePass ? 1 : 0
        bindings.frame.showsWireframe = !isTransmissionPrePass && showsWireframe ? 1 : 0
        bindings.frame.hasTransmissionScene = transmissionScene == nil ? 0 : 1
        bindings.frame.transmissionAsCoverage = transmissionAsCoverage ? 1 : 0
        bindings.frame.transmissionSceneMipCount = Float(transmissionScene?.mipmapLevelCount ?? 1)
        bindings.transmissionScene = transmissionScene ?? shaders.placeholderTexture
        bindings.view = PBRViewUniforms(viewProjectionMatrices: viewPair(viewProjections), modelMatrix: modelMatrix, modelNormalMatrix: modelMatrix.inverse.transpose)

        let plan = drawPlan(cameraPosition: views.centerPosition)
        let context = PipelineContext(shaders: shaders, bindings: bindings, frameResources: bindings.makeFrameResources(), modelIsMirrored: modelMatrix.isMirroring)

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
                try pipeline("PBR Opaque\(group.variant.labelSuffix)\(group.state.labelSuffix)", group.draws, variant: group.variant, state: group.state, context: context)
            }
            ForEach(plan.blendedRuns) { run in
                try pipeline("PBR Blended\(run.variant.labelSuffix)\(run.state.labelSuffix)", run.draws, variant: run.variant, state: run.state, context: context)
            }
        }
        // Long-lived buffers and textures stay resident across frames, including the material textures that are only
        // reached through argument buffers.
        .useResourceCollection(model.resourceCollection)
    }

    private struct PipelineContext {
        var shaders: PBRShaders
        var bindings: PBRFrameBindings
        var frameResources: ArgumentBuffer
        var modelIsMirrored: Bool
    }

    @ElementBuilder
    private func pipeline(_ label: String, _ draws: [PBRDrawPlan.BatchDraw], variant: VertexVariant, state: PBRPipelineState, context: PipelineContext) throws -> some Element {
        // Morphed and unmorphed draws are different element types; choosing per pipeline, not per draw, keeps the
        // per-draw tree small.
        if variant.morphed {
            try pipeline(label, draws, variant: variant, state: state, context: context) { draw in
                morphedDraw(draw)
            }
        } else {
            try pipeline(label, draws, variant: variant, state: state, context: context) { draw in
                self.draw(draw)
            }
        }
    }

    @ElementBuilder
    private func pipeline<Content: Element>(_ label: String, _ draws: [PBRDrawPlan.BatchDraw], variant: VertexVariant, state: PBRPipelineState, context: PipelineContext, draw: @escaping (PBRDrawPlan.BatchDraw) -> Content) throws -> some Element {
        // visionOS shows our color only where depth is written. In stereo, blended surfaces write depth so glass over
        // passthrough stays visible (see PBRPipelineState). They draw back to front, so nearer ones still pass.
        try RenderPipeline(label: label, vertexShader: context.shaders.vertexShader(variant), fragmentShader: context.shaders.fragment) {
            context.bindings.apply(to: ForEach(draws) { batchDraw in
                draw(batchDraw)
            }
            .parameter("view", value: context.bindings.view), frameResources: context.frameResources)
        }
        .vertexDescriptor(variant.skinned ? PBRModel.skinnedVertexDescriptor : PBRModel.vertexDescriptor)
        .renderPipelineDescriptorTransformer { descriptor in
            state.apply(to: descriptor)
        }
        .depthStencilDescriptor(state.depthStencilDescriptor(function: depthFunction))
    }

    /// The bindings that depend only on the lighting, views, debug view and pre-pass stage.
    func makeFrameBindings() throws -> PBRFrameBindings {
        let views = views
        return try PBRFrameBindings(
            lighting: lighting,
            viewProjections: views.viewProjections,
            cameraPositions: views.cameraPositions,
            debugView: isTransmissionPrePass ? .lit : debugView,
            usesAmbientOcclusion: usesAmbientOcclusion
        )
    }

    /// What this renderer draws this frame; see ``PBRDrawPlan``.
    func drawPlan(cameraPosition: SIMD3<Float>) -> PBRDrawPlan {
        PBRDrawPlan(model: model, pose: pose, stage: prePassStage, viewProjections: viewProjections, cameraPosition: cameraPosition, modelMatrix: modelMatrix, usesMergedGeometry: usesMergedGeometry, materialOverrides: materialOverrides, phase: phase, transmissionAsCoverage: transmissionAsCoverage, writesBlendedDepth: writesBlendedDepth, drawsTrianglesOnly: drawsTrianglesOnly)
    }

    /// One Metal draw per visible record of `merged`, all in one element.
    private func mergedDrawCalls(_ merged: PBRMergedGeometry, visible: [Bool]?, doubleSided: [Bool], backFaces: Bool, modelIsMirrored: Bool) -> some Element {
        let indexBuffer = merged.indexBuffer
        return Draw { encoder in
            stereo?.configure(encoder)
            encoder.setTriangleFillMode(.fill)
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
    private func mergedPipeline(_ label: String, vertexShader: VertexShader, vertexDescriptor: MTLVertexDescriptor, merged: PBRMergedGeometry, materials: [PBRMaterialUniforms]?, resources: ArgumentBuffer?, context: PipelineContext, draw: () -> some Element) throws -> some Element {
        let content = draw()
            .vertexBuffer(merged.vertexBuffer, index: 0)
            .parameter("instanceRecords", buffer: merged.instanceRecordBuffer)
            .parameter("recordMaterials", values: materials, else: merged.materialBuffer)
            .parameter("recordResources", argumentBuffer: resources ?? merged.resources)
        return try RenderPipeline(label: label, vertexShader: vertexShader, fragmentShader: context.shaders.mergedFragment) {
            context.bindings.apply(to: content.parameter("view", value: context.bindings.view), frameResources: context.frameResources)
        }
        .vertexDescriptor(vertexDescriptor)
        .depthCompare(function: depthFunction, writes: true)
    }

    /// ``draw(_:)`` plus the morph target inputs, for batches with morph targets.
    func morphedDraw(_ batchDraw: PBRDrawPlan.BatchDraw) -> some Element {
        let primitive = batchDraw.batch.primitive
        let morph = PBRMorphUniforms(targetCount: UInt32(primitive.morphTargetCount), vertexCount: UInt32(primitive.vertexCount))
        return draw(batchDraw)
            .parameter("morph", value: morph)
            .parameter("morphDeltas", buffer: primitive.morphBuffer!)
            .parameter("morphWeights", values: batchDraw.morphWeights ?? [0])
    }

    /// One instanced draw per range of `batchDraw`.
    func draw(_ batchDraw: PBRDrawPlan.BatchDraw) -> some Element {
        let primitive = batchDraw.batch.primitive
        // The primitive's range of the model's shared buffers. Vertex buffers are bound at the primitive's first vertex
        // (baseVertex 0), so vertex_id stays local, as the per-primitive morph buffer expects.
        let geometry = primitive.geometry
        let indexBuffer = geometry.indexBuffer
        let indexCount = primitive.indexCount
        let indexOffset = UInt64(primitive.indexStart * MemoryLayout<UInt32>.stride)
        let primitiveType = primitive.primitiveType
        let draw = Draw { encoder in
            stereo?.configure(encoder)
            encoder.setCullMode(batchDraw.cullMode)
            encoder.setTriangleFillMode(batchDraw.fillMode)
            for range in batchDraw.ranges {
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
            // Later draws outside the renderer expect the default.
            encoder.setTriangleFillMode(.fill)
        }
        // The index buffer is only referenced by address; the model's resource collection keeps it resident and the
        // model keeps it alive.
        .vertexBuffer(geometry.vertexBuffer, index: 0, offset: primitive.baseVertex * MemoryLayout<PBRVertex>.stride)

        return instances(of: batchDraw, on: draw)
            .parameter("material", value: batchDraw.uniforms)
            .parameter("materialResources", argumentBuffer: batchDraw.material.resources)
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
        renderer.frameBindings = nil
        return renderer
    }

    /// This renderer drawing `stereo`'s views.
    func viewing(_ stereo: StereoViews?) -> Self {
        var renderer = self
        renderer.stereo = stereo
        renderer.frameBindings = nil
        return renderer
    }

    /// `renderers` with the first one's frame bindings built once and shared. The caller guarantees they all have the
    /// same lighting, views, debug view and pre-pass stage.
    static func sharingFrameBindings(_ renderers: [PBRRenderer]) throws -> [PBRRenderer] {
        guard renderers.count > 1 else {
            return renderers
        }
        let bindings = try renderers[0].makeFrameBindings()
        return renderers.map { renderer in
            var renderer = renderer
            renderer.frameBindings = bindings
            return renderer
        }
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

    /// Binds joint matrices for skinned batches; otherwise posed instances, or the batch's rest-pose instance buffer.
    @ElementBuilder
    func instances(of batchDraw: PBRDrawPlan.BatchDraw, on content: some Element) -> some Element {
        let primitive = batchDraw.batch.primitive
        if let jointMatrices = batchDraw.jointMatrices, let skinBuffer = primitive.geometry.skinBuffer {
            content
                .vertexBuffer(skinBuffer, index: PBRModel.skinBufferIndex, offset: primitive.baseVertex * MemoryLayout<PBRSkinVertex>.stride)
                .parameter("jointMatrices", values: jointMatrices)
        } else if let instances = batchDraw.instances {
            content.parameter("instances", values: instances)
        } else {
            content.parameter("instances", buffer: batchDraw.batch.instanceBuffer)
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

/// The per-frame inputs of `PBR::shade` (PBRLighting.h): frame uniforms, lights, environment, shadows and screen-space
/// occlusion, with placeholders for what is off. ``PBRRenderer`` uses it; so can other renderers whose shaders build
/// their own `PBR::Fragment`, so their surfaces are lit like PBR meshes.
///
/// ``apply(to:)`` binds by name: `frame`, `lights`, `environmentIrradiance`, `environmentSpecular`, `brdfLookup`,
/// `environmentSampler`, `transmissionScene`, `shadow`, `shadowMap`, `shadowSampler` and `ambientOcclusion`, as
/// `PBR::shade` takes them.
public struct PBRFrameBindings {
    public var frame: PBRFrameUniforms
    /// Never empty: shaders read through a pointer, so an unlit frame binds one unused light.
    public var lights: [LightingLight]
    // PBRRenderer's vertex shaders; not bound by apply(to:).
    var view: PBRViewUniforms
    public var transmissionScene: MTLTexture
    public var irradiance: MTLTexture
    public var specular: MTLTexture
    public var brdfLookup: MTLTexture
    public var sampler: MTLSamplerState
    public var shadow: LightingShadowUniforms
    public var shadowMap: MTLTexture
    public var shadowSampler: MTLSamplerState
    public var ambientOcclusion: MTLTexture

    /// Bindings for `lighting` seen from `viewProjections` (one per view; two in stereo). There is no transmission
    /// scene, so transmissive materials refract the environment.
    public init(lighting: PBRLighting, viewProjections: [simd_float4x4], cameraPositions: [SIMD3<Float>], debugView: PBRDebugView = .lit, usesAmbientOcclusion: Bool = true) throws {
        precondition(!viewProjections.isEmpty && viewProjections.count == cameraPositions.count, "One camera position per view")
        let environment = lighting.environment
        let shaders = try PBRShaders.shared(device: environment.source.device)
        let ambientOcclusion = usesAmbientOcclusion ? lighting.ambientOcclusion : nil
        var frame = PBRFrameUniforms()
        frame.cameraPositions = viewPair(cameraPositions)
        frame.exposure = lighting.exposure
        frame.toneMapping = lighting.toneMapping.shaderValue
        frame.environmentRotation = lighting.environmentRotationMatrix
        frame.lightCount = Int32(lighting.lights.count)
        frame.environmentIntensity = lighting.environmentIntensity
        frame.specularMipCount = Float(environment.specular.mipmapLevelCount)
        frame.viewProjectionMatrices = viewPair(viewProjections)
        frame.debugView = debugView.shaderValue
        frame.transmissionSceneMipCount = 1
        frame.ambientOcclusionStrength = ambientOcclusion?.strength ?? 0
        self.frame = frame
        lights = lighting.lights.isEmpty ? [LightingLight()] : lighting.lights
        view = PBRViewUniforms(viewProjectionMatrices: viewPair(viewProjections), modelMatrix: matrix_identity_float4x4, modelNormalMatrix: matrix_identity_float4x4)
        transmissionScene = shaders.placeholderTexture
        irradiance = environment.irradiance
        specular = environment.specular
        brdfLookup = environment.brdfLookup
        sampler = shaders.environmentSampler
        shadow = lighting.shadows?.uniforms ?? LightingShadowUniforms()
        shadowMap = lighting.shadows?.map ?? shaders.placeholderShadowMap
        shadowSampler = lighting.shadows?.sampler ?? shaders.shadowSampler
        self.ambientOcclusion = ambientOcclusion?.texture ?? shaders.placeholderOcclusion
    }

    /// The textures and samplers as a `LightingFrameResources` argument buffer, for ``apply(to:frameResources:)``. Make it once
    /// per frame and share it between pipelines.
    public func makeFrameResources() -> ArgumentBuffer {
        let resources = ArgumentBuffer(device: irradiance.device, label: "PBR Frame Resources")
        resources.set("environmentIrradiance", texture: irradiance)
        resources.set("environmentSpecular", texture: specular)
        resources.set("brdfLookup", texture: brdfLookup)
        resources.set("transmissionScene", texture: transmissionScene)
        resources.set("shadowMap", texture: shadowMap)
        resources.set("ambientOcclusion", texture: ambientOcclusion)
        resources.set("environmentSampler", samplerState: sampler)
        resources.set("shadowSampler", samplerState: shadowSampler)
        return resources
    }

    /// Binds `frame`, `lights`, `shadow` and `frameResources` (from ``makeFrameResources()``), as the `PBR::shade`
    /// overload that takes a `LightingFrameResources` reads them.
    public func apply(to content: some Element, frameResources: ArgumentBuffer) -> some Element {
        content
            .parameter("frame", value: frame)
            .parameter("lights", values: lights)
            .parameter("shadow", value: shadow)
            .parameter("frameResources", argumentBuffer: frameResources)
    }

    public func apply(to content: some Element) -> some Element {
        content
            .parameter("frame", value: frame)
            .parameter("lights", values: lights)
            .parameter("environmentIrradiance", texture: irradiance)
            .parameter("environmentSpecular", texture: specular)
            .parameter("brdfLookup", texture: brdfLookup)
            .parameter("environmentSampler", samplerState: sampler)
            .parameter("transmissionScene", texture: transmissionScene)
            .parameter("shadow", value: shadow)
            .parameter("shadowMap", texture: shadowMap)
            .parameter("shadowSampler", samplerState: shadowSampler)
            .parameter("ambientOcclusion", texture: ambientOcclusion)
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
    /// Bound as the shadow map when there is none; never sampled then.
    var placeholderShadowMap: MTLTexture
    var placeholderOcclusion: MTLTexture
    var shadowSampler: MTLSamplerState

    private static let cache = Cache()

    /// The shaders and placeholders for `device`, made once per device.
    static func shared(device: MTLDevice) throws -> Self {
        try cache.shaders(for: device)
    }

    // @unchecked: Metal objects are not Sendable, so Mutex cannot hold them; `lock` guards `entries`, the only state,
    // and the shaders are never changed after they are made. Renderers are built on several threads.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [ObjectIdentifier: PBRShaders] = [:]

        func shaders(for device: MTLDevice) throws -> PBRShaders {
            let key = ObjectIdentifier(device)
            if let cached = lock.withLock({ entries[key] }) {
                return cached
            }
            let made = try PBRShaders.make(device: device)
            return lock.withLock {
                if let raced = entries[key] {
                    return raced
                }
                entries[key] = made
                return made
            }
        }
    }

    func vertexShader(_ variant: VertexVariant) -> VertexShader {
        switch (variant.skinned, variant.morphed) {
        case (false, false): vertex
        case (false, true): morphedVertex
        case (true, false): skinnedVertex
        case (true, true): skinnedMorphedVertex
        }
    }

    private static func make(device: MTLDevice) throws -> Self {
        let library = try ShaderLibrary(bundle: .metalSprocketsPBRShaders(), device: device)
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
              }()),
              let placeholderShadowMap = device.makeTexture(descriptor: {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
                descriptor.textureType = .type2DArray
                descriptor.usage = .shaderRead
                descriptor.storageMode = .private
                return descriptor
              }()),
              let placeholderOcclusion = device.makeTexture(descriptor: {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
                descriptor.usage = .shaderRead
                return descriptor
              }()),
              let shadowSampler = device.makeSamplerState(descriptor: {
                let descriptor = MTLSamplerDescriptor()
                descriptor.supportArgumentBuffers = true
                descriptor.minFilter = .linear
                descriptor.magFilter = .linear
                descriptor.sAddressMode = .clampToEdge
                descriptor.tAddressMode = .clampToEdge
                descriptor.compareFunction = .lessEqual
                return descriptor
              }())
        else {
            throw LightingEnvironmentError.resourceCreationFailed("renderer resources")
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
            environmentSampler: sampler,
            placeholderShadowMap: placeholderShadowMap,
            placeholderOcclusion: placeholderOcclusion,
            shadowSampler: shadowSampler
        )
    }
}
