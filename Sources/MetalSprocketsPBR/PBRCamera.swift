import GeometryLite3D
import simd

/// View and projection matrices for rendering a ``PBRModel``.
public struct PBRCamera {
    public var viewMatrix: simd_float4x4
    public var projectionMatrix: simd_float4x4

    public init(viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4) {
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
    }

    /// Orbits `bounds`, keeping all of it in view at `distanceScale` 1. Angles are in radians. The projection uses
    /// reversed depth, as the renderer expects.
    public static func framing(_ bounds: BoundingBox3D, aspectRatio: Float, yaw: Float = .pi / 6, pitch: Float = -.pi / 8, fovY: Float = .pi / 4, distanceScale: Float = 1) -> Self {
        let radius = max(bounds.radius, 1e-3)
        let distance = radius / sin(fovY / 2) * (aspectRatio < 1 ? 1 / aspectRatio : 1) * distanceScale
        let direction = SIMD3<Float>(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
        let eye = bounds.center + direction * distance
        let near = max(distance - radius * 1.5, distance * 0.01)
        let projection = PerspectiveProjection(verticalAngleOfView: .radians(fovY), depthMode: .reversed(zClip: near ... distance + radius * 1.5))
        return Self(
            viewMatrix: LookAt(position: eye, target: bounds.center, up: [0, 1, 0]).viewMatrix,
            projectionMatrix: projection.projectionMatrix(aspectRatio: aspectRatio)
        )
    }
}
