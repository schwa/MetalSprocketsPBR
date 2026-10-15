import GeometryLite3D
import simd

/// The six planes of a view-projection matrix's view volume, for culling bounds that are entirely outside it.
public struct PBRFrustum: Sendable {
    /// Each plane as (normal, distance); points inside satisfy dot(normal, p) + distance >= 0.
    public var planes: [SIMD4<Float>]

    /// `viewProjection` uses Metal clip space: x and y in -w...w, z in 0...w.
    public init(viewProjection: simd_float4x4) {
        let m = viewProjection.transpose
        let (row0, row1, row2, row3) = (m.columns.0, m.columns.1, m.columns.2, m.columns.3)
        planes = [row3 + row0, row3 - row0, row3 + row1, row3 - row1, row2, row3 - row2]
    }

    /// False only when `bounds` is entirely outside one plane. Empty bounds are never visible.
    public func intersects(_ bounds: BoundingBox3D) -> Bool {
        guard !bounds.isEmpty else {
            return false
        }
        for plane in planes {
            let normal = SIMD3(plane.x, plane.y, plane.z)
            // The corner furthest along the plane's normal.
            let corner = bounds.min.replacing(with: bounds.max, where: normal .> 0)
            if simd_dot(normal, corner) + plane.w < 0 {
                return false
            }
        }
        return true
    }
}
