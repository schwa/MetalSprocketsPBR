import GeometryLite3D
import Metal
import MetalSupport
import simd

extension BoundingBox3D {
    /// Like `transformed(by:)`, but empty bounds stay empty instead of becoming NaN.
    func transformedKeepingEmpty(by matrix: simd_float4x4) -> Self {
        isEmpty ? self : transformed(by: matrix)
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
