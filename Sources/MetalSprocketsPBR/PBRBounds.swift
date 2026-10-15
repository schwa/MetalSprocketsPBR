import GeometryLite3D
import Metal
import MetalSupport
import simd

public struct PBRBounds: Equatable, Sendable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    public static let empty = Self(min: SIMD3(repeating: .infinity), max: SIMD3(repeating: -.infinity))

    public var isEmpty: Bool { any(min .> max) }
    public var center: SIMD3<Float> { (min + max) / 2 }
    public var radius: Float { isEmpty ? 0 : simd_length(max - min) / 2 }

    public func union(_ other: Self) -> Self {
        Self(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }

    public func transformed(by matrix: simd_float4x4) -> Self {
        guard !isEmpty else { return self }
        var result = Self.empty
        for corner in 0 ..< 8 {
            let point = SIMD3<Float>(corner & 1 == 0 ? min.x : max.x, corner & 2 == 0 ? min.y : max.y, corner & 4 == 0 ? min.z : max.z)
            let transformed = (matrix * SIMD4(point, 1)).xyz
            result.min = simd_min(result.min, transformed)
            result.max = simd_max(result.max, transformed)
        }
        return result
    }
}

public enum PBRGeometryError: Error {
    case missingPositions
    case bufferAllocationFailed
    /// The attribute's count differs from the position count.
    case attributeCountMismatch(VertexDescriptor.Attribute.Semantic)
    case unsupportedAttributeFormat(VertexDescriptor.Attribute.Semantic, MTLVertexFormat)
    /// A morph target's offsets differ in count from the vertices.
    case morphTargetCountMismatch
}
