import Metal
import MetalSprocketsPBRShaders
import simd

/// The views to draw at once in stereo, e.g. the eyes of a visionOS immersive space: per view a view matrix,
/// projection and viewport. Every draw is amplified into one vertex stream per view, each routed to its viewport and
/// render target array slice (a layered target), so a frame draws its geometry once for both eyes.
public struct PBRStereoViews: Sendable {
    public var viewMatrices: [simd_float4x4]
    public var projectionMatrices: [simd_float4x4]
    public var viewports: [MTLViewport]

    /// One or two views, with equal counts of matrices and viewports. Projections use reversed depth, as everywhere.
    public init(viewMatrices: [simd_float4x4], projectionMatrices: [simd_float4x4], viewports: [MTLViewport]) {
        precondition((1 ... Int(kPBRMaxViewCount)).contains(viewMatrices.count), "One or two views")
        precondition(projectionMatrices.count == viewMatrices.count && viewports.count == viewMatrices.count, "One projection and viewport per view")
        self.viewMatrices = viewMatrices
        self.projectionMatrices = projectionMatrices
        self.viewports = viewports
    }

    public var count: Int { viewMatrices.count }

    var viewProjections: [simd_float4x4] {
        zip(projectionMatrices, viewMatrices).map { $0 * $1 }
    }

    var cameraPositions: [SIMD3<Float>] {
        viewMatrices.map(\.inverse.columns.3.xyz)
    }

    /// Amplifies the following draws into one stream per view, each to its own viewport and array slice. Draws reset
    /// amplification, so every draw calls this.
    func configure(_ encoder: any MTL4RenderCommandEncoder) {
        let mappings = (0 ..< count).map { MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0), renderTargetArrayIndexOffset: UInt32($0)) }
        encoder.setVertexAmplificationCount(mappings)
        encoder.setViewports(viewports)
    }
}

/// Per-view values for the shaders' fixed-size per-view arrays: the second entry repeats the first for one view.
func viewPair<T>(_ values: [T]) -> (T, T) {
    (values[0], values.count > 1 ? values[1] : values[0])
}
