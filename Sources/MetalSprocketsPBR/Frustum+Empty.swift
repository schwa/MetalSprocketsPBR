import GeometryLite3D

extension Frustum {
    /// Like `intersects(_:)`, but empty bounds are never visible.
    func intersectsNonEmpty(_ bounds: BoundingBox3D) -> Bool {
        !bounds.isEmpty && intersects(bounds)
    }
}
