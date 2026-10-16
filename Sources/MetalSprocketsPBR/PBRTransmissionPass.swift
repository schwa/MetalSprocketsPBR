import Metal
import MetalSprockets
import MetalSupport
import simd

/// The render target ``PBRTransmissionPass`` draws the opaque scene into, for transmissive materials to see through.
///
/// Transmissive surfaces look it up in normalised screen coordinates, so any size works, but it should match the view's
/// size: a smaller target makes what is seen through glass look blocky. Its textures are arrays with a slice per view:
/// one, or two for stereo (each eye sees its own view through glass).
public final class PBRTransmissionTarget: @unchecked Sendable {
    /// Linear HDR radiance with a full mip chain; rougher materials read blurrier levels.
    public let color: MTLTexture
    /// Slices, one per view.
    public var viewCount: Int { color.arrayLength }
    let depth: MTLTexture
    /// A copy of the opaque scene, seen by the back faces of double-sided transmissive surfaces. As large as `color`,
    /// so it is only made for scenes that have such surfaces.
    private var backdropTexture: MTLTexture?
    private let backdropLock = NSLock()
    let clearingDescriptor: MTL4RenderPassDescriptor
    let loadingDescriptor: MTL4RenderPassDescriptor

    var hasBackdrop: Bool {
        backdropLock.withLock { backdropTexture != nil }
    }

    /// The backdrop, made on first use.
    func backdrop() throws -> MTLTexture {
        try backdropLock.withLock {
            if let backdropTexture {
                return backdropTexture
            }
            let texture = try color.device.makeTargetTexture(color.pixelFormat, size: PBRTargetSize(width: color.width, height: color.height), usage: color.usage, mipmapped: true, arrayLength: color.arrayLength, label: "PBR Transmission Backdrop")
            backdropTexture = texture
            return texture
        }
    }

    public var width: Int { color.width }
    public var height: Int { color.height }

    public convenience init(device: MTLDevice? = nil, size: Int = 1_024) throws {
        try self.init(device: device, width: size, height: size)
    }

    /// Match the size of the view being rendered: a smaller target looks blocky through glass, as three.js avoids by
    /// sizing its own to the drawing buffer. `viewCount` is 2 for stereo.
    public init(device: MTLDevice? = nil, width: Int, height: Int, viewCount: Int = 1) throws {
        let device = device ?? _MTLCreateSystemDefaultDevice()
        let size = PBRTargetSize(width: width, height: height)
        let viewCount = max(viewCount, 1)
        let color = try device.makeTargetTexture(.rgba16Float, size: size, usage: [.renderTarget, .shaderRead], mipmapped: true, arrayLength: viewCount, label: "PBR Transmission Scene")
        let depth = try device.makeTargetTexture(.depth32Float, size: size, usage: .renderTarget, arrayLength: viewCount, label: "PBR Transmission Depth")
        self.color = color
        self.depth = depth

        func descriptor(load: Bool) -> MTL4RenderPassDescriptor {
            let descriptor = MTL4RenderPassDescriptor()
            descriptor.colorAttachments[0].texture = color
            descriptor.colorAttachments[0].loadAction = load ? .load : .clear
            // Alpha 0 where nothing is drawn: stereo coverage uses it to tell the model behind glass from passthrough.
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.depthAttachment.texture = depth
            descriptor.depthAttachment.loadAction = load ? .load : .clear
            // Reversed depth: far is 0.
            descriptor.depthAttachment.clearDepth = 0
            descriptor.depthAttachment.storeAction = .store
            // Layered: stereo draws route each eye to its slice.
            descriptor.renderTargetArrayLength = viewCount
            return descriptor
        }
        clearingDescriptor = descriptor(load: false)
        loadingDescriptor = descriptor(load: true)
    }
}

/// Renders the non-transmissive part of the scene into a ``PBRTransmissionTarget`` and builds its mip chain.
///
/// Like three.js, it then adds the back faces of double-sided transmissive surfaces, so glass shows its far side.
/// Place it before the `RenderPass` that draws ``PBRRenderer``, and give that renderer the same target and inputs:
///
/// ```swift
/// try PBRTransmissionPass(model: model, viewMatrix: view, projectionMatrix: projection, target: target)
/// try RenderPass {
///     PBRRenderer(model: model, viewMatrix: view, projectionMatrix: projection, transmissionTarget: target)
/// }
/// ```
public struct PBRTransmissionPass<AdditionalContent: Element>: Element {
    public var renderer: PBRRenderer
    /// Further models drawn into the same target after `renderer`'s (by ``PBRScene`` with several models).
    var additionalRenderers: [PBRRenderer] = []
    public var target: PBRTransmissionTarget
    /// Also draw the environment behind the scene, so glass shows it.
    public var showsBackground: Bool
    /// Non-PBR opaque content drawn into the target after the PBR renderers, with the same reversed depth and view
    /// amplification. It must write linear (not tone-mapped) radiance.
    public var additionalContent: AdditionalContent

    public init(model: PBRModel, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4 = matrix_identity_float4x4, lighting: PBRLighting? = nil, pose: PBRPose? = nil, target: PBRTransmissionTarget, showsBackground: Bool = false, @ElementBuilder additionalContent: () throws -> AdditionalContent) rethrows {
        let renderer = PBRRenderer(model: model, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, modelMatrix: modelMatrix, lighting: lighting, pose: pose, transmissionTarget: target)
        try self.init(renderers: [renderer], target: target, showsBackground: showsBackground, additionalContent: additionalContent)
    }

    /// The opaque scene of every renderer's model, configured as for the main pass (overrides, stereo, ...). The first
    /// renderer's lighting and views draw the background.
    public init(renderers: [PBRRenderer], target: PBRTransmissionTarget, showsBackground: Bool = false, @ElementBuilder additionalContent: () throws -> AdditionalContent) rethrows {
        precondition(!renderers.isEmpty, "A transmission pass draws at least one model")
        renderer = renderers[0].prePass(.opaque)
        additionalRenderers = renderers.dropFirst().map { $0.prePass(.opaque) }
        self.target = target
        self.showsBackground = showsBackground
        self.additionalContent = try additionalContent()
    }

    public var body: some Element {
        get throws {
            try content()
        }
    }

    func content() throws -> some Element {
        let color = target.color
        // In stereo, each eye draws into its own slice of the target, covering all of it.
        let stereo = renderer.stereo.map { views in
            let viewport = MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1)
            return PBRStereoViews(viewMatrices: views.viewMatrices, projectionMatrices: views.projectionMatrices, viewports: Array(repeating: viewport, count: views.count))
        }
        let viewCount = stereo?.count ?? 1
        var background = PBREnvironmentBackground(lighting: renderer.lighting, viewMatrix: renderer.viewMatrix, projectionMatrix: renderer.projectionMatrix)
        background.linearOutput = true
        background.stereo = stereo
        let renderers = ([renderer] + additionalRenderers).map { $0.viewing(stereo) }
        let backFaces = renderers.map { $0.prePass(.transmissiveBackFaces) }
        let hasBackFaces = renderers.contains { renderer in
            (renderer.model.opaqueBatches + renderer.model.blendedBatches).contains { batch in
                let material = batch.material(overrides: renderer.materialOverrides)
                return material.isTransmissive && material.doubleSided
            }
        }
        return try Group {
            try RenderPass(label: "PBR Transmission Scene") {
                try Group {
                    if showsBackground {
                        background
                    }
                    PBRRenderer.all(renderers)
                    additionalContent
                }
                .renderPipelineDescriptorTransformer { $0.maxVertexAmplificationCount = viewCount }
            }
            .renderPassDescriptor(target.clearingDescriptor)
            if hasBackFaces {
                let backdrop = try target.backdrop()
                try ComputePass(label: "PBR Transmission Backdrop") {
                    QueueBarrier(after: .fragment, before: .blit)
                    ComputeCommand { encoder in
                        encoder.copy(sourceTexture: color, sourceSlice: 0, sourceLevel: 0, destinationTexture: backdrop, destinationSlice: 0, destinationLevel: 0, sliceCount: color.arrayLength, levelCount: 1)
                    }
                    .useComputeResources([color, backdrop], usage: [.read, .write])
                    EncoderBarrier(after: .blit, before: .blit)
                    ComputeCommand { encoder in
                        encoder.generateMipmaps(texture: backdrop)
                    }
                    .useComputeResource(backdrop, usage: [.read, .write])
                }
                try RenderPass(label: "PBR Transmission Back Faces") {
                    try Group {
                        PBRRenderer.all(backFaces)
                    }
                    .renderPipelineDescriptorTransformer { $0.maxVertexAmplificationCount = viewCount }
                }
                .renderPassDescriptor(target.loadingDescriptor)
            }
            try ComputePass(label: "PBR Transmission Mipmaps") {
                QueueBarrier(after: .fragment, before: .blit)
                ComputeCommand { encoder in
                    encoder.generateMipmaps(texture: color)
                }
                .useComputeResource(color, usage: [.read, .write])
            }
        }
    }
}

public extension PBRTransmissionPass where AdditionalContent == EmptyElement {
    init(model: PBRModel, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4 = matrix_identity_float4x4, lighting: PBRLighting? = nil, pose: PBRPose? = nil, target: PBRTransmissionTarget, showsBackground: Bool = false) {
        self.init(model: model, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, modelMatrix: modelMatrix, lighting: lighting, pose: pose, target: target, showsBackground: showsBackground) { EmptyElement() }
    }

    init(renderers: [PBRRenderer], target: PBRTransmissionTarget, showsBackground: Bool = false) {
        self.init(renderers: renderers, target: target, showsBackground: showsBackground) { EmptyElement() }
    }
}
