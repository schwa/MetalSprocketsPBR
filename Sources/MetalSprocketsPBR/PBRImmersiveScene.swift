#if os(visionOS)
import Metal
import MetalSprockets
import MetalSprocketsUI
import simd

/// Draws models in a visionOS immersive space: both eyes at once (``StereoViews``), into the compositor's
/// layered, reverse-Z targets, inside an `ImmersiveRenderPass` (so progressive immersion masks it).
///
/// ```swift
/// ImmersiveSpace(id: "Model") {
///     ImmersiveRenderContent { context in
///         PBRImmersiveScene(model: model, context: context, modelMatrix: placement)
///     }
/// }
/// ```
///
/// Positions are in meters in the space's coordinates, so place the model with `modelMatrix` (e.g. 1.5 m in front at
/// eye height, scaled to a comfortable size). Models with glass or liquid get a stereo transmission pre-pass, so each
/// eye sees the scene behind them refracted from its own viewpoint.
public struct PBRImmersiveScene: Element {
    public var items: [PBRScene.Item]
    public var context: ImmersiveContext
    /// Nil uses every item's lights at rest with the studio environment.
    public var lighting: PBRLighting?
    /// Draw the environment around the viewer (full immersion); off for mixed immersion, which shows the room.
    public var showsBackground = false
    public var debugView: PBRDebugView = .lit

    @MSState private var transmissionTargets = PBRTargetCache<PBRTransmissionTarget>()

    public init(items: [PBRScene.Item], context: ImmersiveContext, lighting: PBRLighting? = nil) {
        precondition(!items.isEmpty, "A scene draws at least one model")
        self.items = items
        self.context = context
        self.lighting = lighting
    }

    public init(model: PBRModel, context: ImmersiveContext, modelMatrix: simd_float4x4 = matrix_identity_float4x4, lighting: PBRLighting? = nil, pose: PBRPose? = nil) {
        self.init(items: [PBRScene.Item(model: model, pose: pose, modelMatrix: modelMatrix)], context: context, lighting: lighting)
    }

    var stereo: StereoViews {
        context.stereoViews
    }

    public var body: some Element {
        get throws {
            let lighting = lighting ?? PBRLighting(lights: items.flatMap(\.model.lights))
            let stereo = stereo
            var background = PBREnvironmentBackground(lighting: lighting, viewMatrix: stereo.viewMatrices[0], projectionMatrix: stereo.projectionMatrices[0])
            background.stereo = stereo
            let viewCount = context.viewCount
            // Debug views do not show what is behind glass, so they skip the pre-pass. The target matches an eye's
            // view in the compositor's texture.
            let viewport = stereo.viewports[0]
            let target = PBRScene.needsTransmissionPass(items, debugView: debugView) ? try transmissionTargets.target(for: .init(width: Int(viewport.width), height: Int(viewport.height), viewCount: viewCount, device: items[0].model.device)) : nil
            func renderer(_ item: PBRScene.Item) -> PBRRenderer {
                var renderer = PBRRenderer(model: item.model, viewMatrix: stereo.viewMatrices[0], projectionMatrix: stereo.projectionMatrices[0], modelMatrix: item.modelMatrix, lighting: lighting, pose: item.pose, transmissionTarget: target)
                renderer.stereo = stereo
                // The compositor's pass can be foveated (a rasterization rate map), which allows only triangles.
                renderer.drawsTrianglesOnly = true
                renderer.materialOverrides = item.materialOverrides
                renderer.debugView = debugView
                return renderer
            }
            let renderers = try PBRRenderer.sharingFrameBindings(PBRScene.renderers(items, cameraPosition: PBRViews(viewMatrix: stereo.viewMatrices[0], projectionMatrix: stereo.projectionMatrices[0], stereo: stereo).centerPosition, make: renderer))
            var transmissionPass = target.map { PBRTransmissionPass(renderers: items.map(renderer), target: $0, showsBackground: showsBackground) }
            transmissionPass?.sharesFrameBindings = true
            return try Group {
                if let transmissionPass {
                    // Not the compositor's pass: without this, its render pass would end through the compositor's
                    // render context, which also ends the command buffer, and nothing after it could be encoded.
                    transmissionPass
                        .immersiveRenderContext(nil)
                }
                try ImmersiveRenderPass(context: context, label: "PBR Immersive") {
                    // Every pipeline draws each primitive once per eye.
                    try Group {
                        if showsBackground {
                            background
                        }
                        PBRRenderer.all(renderers)
                    }
                    .renderPipelineDescriptorTransformer { $0.maxVertexAmplificationCount = viewCount }
                }
            }
        }
    }
}
#endif
