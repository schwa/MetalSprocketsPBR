import CoreGraphics
import Metal
import MetalFX
import MetalSprockets
import MetalSupport
import simd

/// Everything needed to draw one or more models into the current render target: the transmission pre-pass (when a
/// model has transmissive materials), the render pass, the optional environment background and the models.
///
/// Use it in place of assembling ``PBRTransmissionPass``, `RenderPass`, ``PBREnvironmentBackground`` and
/// ``PBRRenderer`` by hand. It keeps a transmission target matching `viewportSize` across frames.
///
/// ```swift
/// RenderView { _, size in
///     PBRScene(model: model, viewMatrix: view, projectionMatrix: projection, viewportSize: size)
/// }
/// .metalDepthStencilPixelFormat(.depth32Float)
/// .metalClearDepth(0)
/// ```
///
/// Depth is reversed (near 1, far 0): use `simd_float4x4.perspective` or `PBRCamera` for projections, and clear
/// depth to 0 (`OffscreenRenderer(size:clearDepth: 0)`, or `metalClearDepth(0)` on a `RenderView`).
///
/// With several models (``items``), blended surfaces of all of them are sorted back to front together, and glass in
/// one model shows the others behind it. Models stay immutable; add or remove items to change the scene.
public struct PBRScene: Element {
    /// A model placed in the scene, with its own pose, placement and material overrides.
    public struct Item {
        public var model: PBRModel
        /// Nil draws the model at rest.
        public var pose: PBRPose?
        public var modelMatrix: simd_float4x4
        public var materialOverrides: PBRModel.MaterialOverrides

        public init(model: PBRModel, pose: PBRPose? = nil, modelMatrix: simd_float4x4 = matrix_identity_float4x4, materialOverrides: PBRModel.MaterialOverrides = [:]) {
            self.model = model
            self.pose = pose
            self.modelMatrix = modelMatrix
            self.materialOverrides = materialOverrides
        }
    }

    /// The models to draw; at least one.
    public var items: [Item]
    public var viewMatrix: simd_float4x4
    public var projectionMatrix: simd_float4x4
    /// Nil uses every item's lights at rest with the studio environment.
    public var lighting: PBRLighting?
    public var showsBackground: Bool
    /// The render target's size in pixels; glass and liquid sample a transmission target of the same size.
    public var viewportSize: CGSize
    /// Output one shading input instead of the lit color, for debugging.
    public var debugView: PBRDebugView = .lit
    /// Draw triangle edges over the output.
    public var showsWireframe = false
    /// Multisample antialiasing for the main pass when rendering to a texture, such as with OffscreenRenderer. Above 1,
    /// the pass draws into a multisampled target and resolves into the current one. On screen, keep this at 1 and set
    /// RenderView's sampleCount instead. The transmission pre-pass is not multisampled.
    public var sampleCount = 1
    /// Draw at a lower resolution and upscale to the target with MetalFX spatial scaling. Nil draws at full size.
    /// MetalFX needs antialiased input, so `sampleCount` applies to the low-resolution frame. On screen, set it here
    /// and keep the view's sample count at 1.
    public var upscaling: PBRUpscaling?

    @MSState private var transmissionTargets = PBRTransmissionTargetCache()
    @MSState private var upscaleTargets = PBRUpscaleTargetCache()

    /// Several models in one scene.
    public init(items: [Item], viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, lighting: PBRLighting? = nil, showsBackground: Bool = false, viewportSize: CGSize) {
        precondition(!items.isEmpty, "A scene draws at least one model")
        self.items = items
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.lighting = lighting
        self.showsBackground = showsBackground
        self.viewportSize = viewportSize
    }

    /// One model.
    public init(model: PBRModel, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4 = matrix_identity_float4x4, lighting: PBRLighting? = nil, pose: PBRPose? = nil, showsBackground: Bool = false, viewportSize: CGSize) {
        self.init(items: [Item(model: model, pose: pose, modelMatrix: modelMatrix)], viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, lighting: lighting, showsBackground: showsBackground, viewportSize: viewportSize)
    }

    // The first item's parts, for one-model scenes.

    public var model: PBRModel {
        get { items[0].model }
        set { items[0].model = newValue }
    }

    public var pose: PBRPose? {
        get { items[0].pose }
        set { items[0].pose = newValue }
    }

    public var modelMatrix: simd_float4x4 {
        get { items[0].modelMatrix }
        set { items[0].modelMatrix = newValue }
    }

    /// Materials to draw primitives with instead of their own, e.g. a material variant (``PBRModel/MaterialOverrides``).
    public var materialOverrides: PBRModel.MaterialOverrides {
        get { items[0].materialOverrides }
        set { items[0].materialOverrides = newValue }
    }

    public var body: some Element {
        get throws {
            try content()
        }
    }

    func content() throws -> some Element {
        let lighting = lighting ?? PBRLighting(lights: items.flatMap(\.model.lights))
        let upscale = try upscaling.flatMap { try upscaleTargets.targets(for: $0, outputSize: viewportSize) }
        let renderSize = upscale.map { CGSize(width: $0.color.width, height: $0.color.height) } ?? viewportSize
        // Debug views do not show what is behind glass, so they skip the transmission pre-pass.
        let hasTransmission = items.contains(where: \.model.hasTransmission)
        let target = hasTransmission && debugView == .lit ? try transmissionTargets.target(width: Int(renderSize.width), height: Int(renderSize.height)) : nil
        return try Group {
            if let target {
                transmissionPass(lighting: lighting, target: target)
            }
            if let upscale {
                try upscaledPasses(lighting: lighting, target: target, upscale: upscale)
            } else if sampleCount > 1 {
                try mainPass(lighting: lighting, target: target)
                    .msaa(sampleCount: sampleCount)
            } else {
                try mainPass(lighting: lighting, target: target)
            }
        }
    }

    /// The main pass into the low-resolution targets, MetalFX upscaling, and a copy into the current target.
    private func upscaledPasses(lighting: PBRLighting, target: PBRTransmissionTarget?, upscale: PBRUpscaleTargets) throws -> some Element {
        let shaders = try PBRShaders.shared()
        let lowResolution: (MTL4RenderPassDescriptor) -> Void = { descriptor in
            descriptor.colorAttachments[0].texture = upscale.color
            descriptor.colorAttachments[0].resolveTexture = nil
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.depthAttachment.texture = upscale.depth
            descriptor.depthAttachment.resolveTexture = nil
            descriptor.depthAttachment.storeAction = .dontCare
        }
        return try Group {
            // The modifier is outside the MSAA one so MSAA resolves into the low-resolution target.
            if sampleCount > 1 {
                try mainPass(lighting: lighting, target: target)
                    .msaa(sampleCount: sampleCount)
                    .renderPassDescriptorModifier(lowResolution)
            } else {
                try mainPass(lighting: lighting, target: target)
                    .renderPassDescriptorModifier(lowResolution)
            }
            MetalFXSpatial(inputTexture: upscale.color, outputTexture: upscale.output)
            try RenderPass {
                try RenderPipeline(label: "PBR Upscale Copy", vertexShader: shaders.backgroundVertex, fragmentShader: shaders.copyFragment) {
                    Draw { encoder in
                        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                    .parameter("source", texture: upscale.output)
                }
                .depthCompare(function: .always, enabled: false)
            }
        }
        .useResourceCollection(upscale.resources)
    }

    private func mainPass(lighting: PBRLighting, target: PBRTransmissionTarget?) throws -> some Element {
        let renderers = mainRenderers(lighting: lighting, target: target)
        return try RenderPass {
            if showsBackground {
                PBREnvironmentBackground(lighting: lighting, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix)
            }
            PBRRenderer.all(renderers)
        }
    }

    private func renderer(_ item: Item, lighting: PBRLighting, target: PBRTransmissionTarget?) -> PBRRenderer {
        var renderer = PBRRenderer(model: item.model, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, modelMatrix: item.modelMatrix, lighting: lighting, pose: item.pose, transmissionTarget: target)
        renderer.debugView = debugView
        renderer.showsWireframe = showsWireframe
        renderer.materialOverrides = item.materialOverrides
        return renderer
    }

    /// One model draws everything with one renderer. Several draw their opaque batches first, one renderer each,
    /// then every blended batch in one back-to-front order, a renderer for each run of one model's batches.
    private func mainRenderers(lighting: PBRLighting, target: PBRTransmissionTarget?) -> [PBRRenderer] {
        Self.renderers(items, cameraPosition: viewMatrix.inverse.columns.3.xyz) { renderer($0, lighting: lighting, target: target) }
    }

    /// The renderers that draw `items`, made by `make`: one per item for opaque batches, then one per run of an
    /// item's blended batches in a shared back-to-front order (see ``blendedRuns(_:cameraPosition:)``).
    static func renderers(_ items: [Item], cameraPosition: SIMD3<Float>, make: (Item) -> PBRRenderer) -> [PBRRenderer] {
        guard items.count > 1 else {
            return [make(items[0])]
        }
        // Each item's plan keeps a given blended order, so the batches are sorted once, here, across items.
        let opaque = items.map { make($0).drawing(.opaque) }
        let blended = blendedRuns(items, cameraPosition: cameraPosition).map { make(items[$0.item]).drawing(.blended($0.batches)) }
        return opaque + blended
    }

    /// Every item's blended batches sorted back to front by their centers, split into runs of consecutive batches
    /// from the same item.
    static func blendedRuns(_ items: [Item], cameraPosition: SIMD3<Float>) -> [(item: Int, batches: [Int])] {
        var entries: [(item: Int, batch: Int, distance: Float)] = []
        for (index, item) in items.enumerated() {
            for batch in item.model.blendedBatches {
                let bounds = item.pose.map { item.model.worldBounds(of: batch, pose: $0) } ?? batch.worldBounds
                entries.append((index, batch.id, simd_distance_squared(bounds.transformed(by: item.modelMatrix).center, cameraPosition)))
            }
        }
        entries.sort { $0.distance > $1.distance }
        var runs: [(item: Int, batches: [Int])] = []
        for entry in entries {
            if let last = runs.last, last.item == entry.item {
                runs[runs.count - 1].batches.append(entry.batch)
            } else {
                runs.append((entry.item, [entry.batch]))
            }
        }
        return runs
    }

    private func transmissionPass(lighting: PBRLighting, target: PBRTransmissionTarget) -> PBRTransmissionPass {
        PBRTransmissionPass(renderers: items.map { renderer($0, lighting: lighting, target: target) }, target: target, showsBackground: showsBackground)
    }
}

/// Rendering at a fraction of the target's size, upscaled with MetalFX spatial scaling (``PBRScene/upscaling``).
public struct PBRUpscaling: Sendable, Equatable {
    /// The fraction of the target's width and height drawn, in (0, 1].
    public var scale: Float
    /// The current target's color format; the low-resolution frame and the upscaled one use it too.
    public var colorPixelFormat: MTLPixelFormat
    public var depthPixelFormat: MTLPixelFormat

    public init(scale: Float, colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb, depthPixelFormat: MTLPixelFormat = .depth32Float) {
        self.scale = scale
        self.colorPixelFormat = colorPixelFormat
        self.depthPixelFormat = depthPixelFormat
    }

    /// Whether this device can upscale with MetalFX.
    public static func isSupported(device: MTLDevice) -> Bool {
        MTLFXSpatialScalerDescriptor.supportsMetal4FX(device)
    }
}
