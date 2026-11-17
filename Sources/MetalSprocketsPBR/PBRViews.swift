import MetalSprockets
import simd

/// The views an element draws: one (mono), or a ``StereoViews`` drawn at once.
struct PBRViews {
    var viewMatrices: [simd_float4x4]
    var projectionMatrices: [simd_float4x4]
    /// Set for stereo; configures the encoder's amplification and viewports.
    var stereo: StereoViews?

    init(viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, stereo: StereoViews?) {
        viewMatrices = stereo?.viewMatrices ?? [viewMatrix]
        projectionMatrices = stereo?.projectionMatrices ?? [projectionMatrix]
        self.stereo = stereo
    }

    var isStereo: Bool { stereo != nil }

    var viewProjections: [simd_float4x4] {
        zip(projectionMatrices, viewMatrices).map { $0 * $1 }
    }

    var cameraPositions: [SIMD3<Float>] {
        viewMatrices.map(\.inverse.columns.3.xyz)
    }

    /// Between the eyes in stereo; blended batches are sorted from here.
    var centerPosition: SIMD3<Float> {
        let positions = cameraPositions
        return positions.reduce(.zero, +) / Float(positions.count)
    }

    /// View-projections without the views' translation, for the environment background.
    var inverseRotationViewProjections: [simd_float4x4] {
        zip(projectionMatrices, viewMatrices).map { projection, view in
            var rotationOnly = view
            rotationOnly.columns.3 = [0, 0, 0, 1]
            return (projection * rotationOnly).inverse
        }
    }
}
