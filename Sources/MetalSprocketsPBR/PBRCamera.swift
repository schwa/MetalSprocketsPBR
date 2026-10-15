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

    /// Orbits `bounds`, keeping all of it in view at `distanceScale` 1. Angles are in radians.
    public static func framing(_ bounds: BoundingBox3D, aspectRatio: Float, yaw: Float = .pi / 6, pitch: Float = -.pi / 8, fovY: Float = .pi / 4, distanceScale: Float = 1) -> Self {
        let radius = max(bounds.radius, 1e-3)
        let distance = radius / sin(fovY / 2) * (aspectRatio < 1 ? 1 / aspectRatio : 1) * distanceScale
        let direction = SIMD3<Float>(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
        let eye = bounds.center + direction * distance
        return Self(
            viewMatrix: .lookAt(eye: eye, target: bounds.center, up: [0, 1, 0]),
            projectionMatrix: .perspective(fovY: fovY, aspectRatio: aspectRatio, near: max(distance - radius * 1.5, distance * 0.01), far: distance + radius * 1.5)
        )
    }

    /// A camera defined in the glTF file, placed by its node.
}

public extension simd_float4x4 {
    /// A right-handed perspective projection with reversed depth: `near` maps to depth 1 and `far` to 0, as the
    /// renderer expects everywhere (and visionOS's compositor requires). Clear depth to 0.
    static func perspective(fovY: Float, aspectRatio: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2)
        let x = y / aspectRatio
        let z = near / (far - near)
        return simd_float4x4(columns: ([x, 0, 0, 0], [0, y, 0, 0], [0, 0, z, -1], [0, 0, z * far, 0]))
    }

    /// An orthographic projection with reversed depth, like ``perspective(fovY:aspectRatio:near:far:)``.
    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> simd_float4x4 {
        let depth = 1 / (far - near)
        return simd_float4x4(columns: ([1 / halfWidth, 0, 0, 0], [0, 1 / halfHeight, 0, 0], [0, 0, depth, 0], [0, 0, far * depth, 1]))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross(up, forward))
        let trueUp = simd_cross(forward, right)
        return simd_float4x4(columns: (
            [right.x, trueUp.x, forward.x, 0],
            [right.y, trueUp.y, forward.y, 0],
            [right.z, trueUp.z, forward.z, 0],
            [-simd_dot(right, eye), -simd_dot(trueUp, eye), -simd_dot(forward, eye), 1]
        ))
    }
}
