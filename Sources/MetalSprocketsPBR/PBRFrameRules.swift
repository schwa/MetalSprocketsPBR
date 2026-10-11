import MetalSprocketsPBRShaders
import simd

// Per-frame rules shared by the draw plan, merged geometry and the renderer, so merged and per-batch drawing agree on
// placement, visibility, bounds and materials.

extension PBRPose {
    /// A node's world matrix; identity for nodes the pose does not cover.
    func worldMatrix(ofNode node: Int) -> simd_float4x4 {
        worldMatrices.indices.contains(node) ? worldMatrices[node] : matrix_identity_float4x4
    }

    /// Where an instance placed by `node` with `instanceMatrix` is drawn.
    func placement(node: Int, instanceMatrix: simd_float4x4) -> simd_float4x4 {
        worldMatrix(ofNode: node) * instanceMatrix
    }

    /// World bounds of `localBounds` placed at each visible instance.
    func bounds(of localBounds: PBRBounds, nodes: [Int], instanceMatrices: [simd_float4x4]) -> PBRBounds {
        zip(nodes, instanceMatrices).reduce(PBRBounds.empty) { result, instance in
            guard isVisible(instance.0) else { return result }
            return result.union(localBounds.transformed(by: placement(node: instance.0, instanceMatrix: instance.1)))
        }
    }

    /// `material`'s uniforms at this moment: animated (KHR_animation_pointer) or its own.
    func uniforms(of material: PBRMaterial) -> PBRMaterialUniforms {
        materialUniforms[ObjectIdentifier(material)] ?? material.uniforms
    }
}

extension simd_float4x4 {
    /// Whether this transform flips winding.
    var isMirroring: Bool { simd_determinant(self) < 0 }
}

extension PBRModel.MaterialOverrides {
    /// The material `key`'s primitive is drawn with: its override, or `material`.
    func material(for key: PBRModel.Primitive.Key, default material: PBRMaterial) -> PBRMaterial {
        isEmpty ? material : self[key] ?? material
    }
}

extension PBRModel.Batch {
    /// The material this batch is drawn with.
    func material(overrides: PBRModel.MaterialOverrides) -> PBRMaterial {
        overrides.material(for: primitive.key, default: material)
    }
}

extension PBRMaterialUniforms {
    /// These uniforms with a primitive's vertex inputs, which the shader branches on.
    func forPrimitive(hasTangents: Bool, hasNormals: Bool) -> Self {
        var uniforms = self
        uniforms.hasTangents = hasTangents ? 1 : 0
        uniforms.hasNormals = hasNormals ? 1 : 0
        return uniforms
    }

    /// `material`'s uniforms for drawing `primitive` with `pose` (nil: at rest).
    static func resolved(_ material: PBRMaterial, primitive: PBRModel.Primitive, pose: PBRPose?) -> Self {
        (pose?.uniforms(of: material) ?? material.uniforms).forPrimitive(hasTangents: primitive.hasTangents, hasNormals: primitive.hasNormals)
    }
}
