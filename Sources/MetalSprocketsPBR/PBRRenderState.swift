import Metal

/// How ``PBRRenderer`` draws a material: blending, depth, color writes and fill mode. The defaults follow the
/// material's alpha mode.
public struct PBRRenderState: Hashable, Sendable {
    public enum BlendMode: Hashable, Sendable {
        case opaque
        /// Straight alpha: source * alpha + destination * (1 - alpha).
        case alpha
        /// Premultiplied alpha: source + destination * (1 - alpha).
        case premultiplied
        /// source * alpha + destination.
        case additive
    }

    public enum FillMode: Hashable, Sendable {
        case fill
        case lines
    }

    public enum DepthWrite: Hashable, Sendable {
        /// Opaque materials write depth, blended ones do not.
        case automatic
        case enabled
        case disabled

        func resolved(blended: Bool) -> Bool {
            switch self {
            case .automatic: !blended
            case .enabled: true
            case .disabled: false
            }
        }
    }

    public struct ColorWriteMask: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let red = Self(rawValue: 1 << 0)
        public static let green = Self(rawValue: 1 << 1)
        public static let blue = Self(rawValue: 1 << 2)
        public static let alpha = Self(rawValue: 1 << 3)
        public static let all: Self = [.red, .green, .blue, .alpha]
        public static let none: Self = []
    }

    /// Nil: `.alpha` for `alphaMode` blend, else `.opaque`. Anything but `.opaque` draws with the blended batches, back
    /// to front.
    public var blendMode: BlendMode?
    /// False draws whatever is already in the depth buffer.
    public var depthTest: Bool
    /// In stereo (visionOS) blended materials always write depth, so the compositor shows them.
    public var depthWrite: DepthWrite
    public var colorWriteMask: ColorWriteMask
    public var fillMode: FillMode

    public init(blendMode: BlendMode? = nil, depthTest: Bool = true, depthWrite: DepthWrite = .automatic, colorWriteMask: ColorWriteMask = .all, fillMode: FillMode = .fill) {
        self.blendMode = blendMode
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.colorWriteMask = colorWriteMask
        self.fillMode = fillMode
    }

    /// Nothing set beyond what the alpha mode implies; such materials can be merged.
    public var isDefault: Bool {
        depthTest && depthWrite == .automatic && colorWriteMask == .all && fillMode == .fill && (blendMode == nil || blendMode == .opaque)
    }

    func resolvedBlendMode(alphaMode: PBRAlphaMode) -> BlendMode {
        blendMode ?? (alphaMode == .blend ? .alpha : .opaque)
    }
}

/// The pipeline and depth state one per-batch pipeline draws with: its batches' render states, resolved.
struct PBRPipelineState: Hashable {
    var blendMode: PBRRenderState.BlendMode
    var colorWriteMask: PBRRenderState.ColorWriteMask
    var depthTest: Bool
    var depthWrite: Bool

    static let opaque = Self(blendMode: .opaque, colorWriteMask: .all, depthTest: true, depthWrite: true)

    init(blendMode: PBRRenderState.BlendMode, colorWriteMask: PBRRenderState.ColorWriteMask, depthTest: Bool, depthWrite: Bool) {
        self.blendMode = blendMode
        self.colorWriteMask = colorWriteMask
        self.depthTest = depthTest
        self.depthWrite = depthWrite
    }

    /// - Parameter writesBlendedDepth: Stereo: blended surfaces write depth whatever the material says.
    init(_ material: PBRMaterial, writesBlendedDepth: Bool) {
        let state = material.renderState
        blendMode = state.resolvedBlendMode(alphaMode: material.uniforms.alphaMode)
        colorWriteMask = state.colorWriteMask
        depthTest = state.depthTest
        let blended = blendMode != .opaque
        depthWrite = blended && writesBlendedDepth ? true : state.depthWrite.resolved(blended: blended)
    }

    var labelSuffix: String {
        var suffix = switch blendMode {
        case .opaque: ""
        case .alpha: ""
        case .premultiplied: " Premultiplied"
        case .additive: " Additive"
        }
        if colorWriteMask != .all {
            suffix += " Masked"
        }
        if !depthTest {
            suffix += " No Depth Test"
        }
        return suffix
    }

    func apply(to descriptor: MTL4RenderPipelineDescriptor) {
        let attachment = descriptor.colorAttachments[0]!
        var mask: MTLColorWriteMask = []
        if colorWriteMask.contains(.red) { mask.insert(.red) }
        if colorWriteMask.contains(.green) { mask.insert(.green) }
        if colorWriteMask.contains(.blue) { mask.insert(.blue) }
        if colorWriteMask.contains(.alpha) { mask.insert(.alpha) }
        attachment.writeMask = mask
        guard blendMode != .opaque else { return }
        attachment.blendingState = .enabled
        attachment.sourceRGBBlendFactor = blendMode == .premultiplied ? .one : .sourceAlpha
        attachment.destinationRGBBlendFactor = blendMode == .additive ? .one : .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = blendMode == .additive ? .one : .oneMinusSourceAlpha
    }

    func depthStencilDescriptor(function: MTLCompareFunction) -> MTLDepthStencilDescriptor {
        MTLDepthStencilDescriptor(depthCompareFunction: depthTest ? function : .always, isDepthWriteEnabled: depthWrite)
    }
}
