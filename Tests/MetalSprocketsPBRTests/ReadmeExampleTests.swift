import Metal
import MetalSprocketsPBR
import Testing

// Keep in sync with README.md's Usage section.
struct ReadmeExampleTests {
    @Test func buildsAModelInCode() throws {
        let device = MTLCreateSystemDefaultDevice()!

        var geometry = PBRGeometryBuilder(device: device)
        let positions: [SIMD3<Float>] = [[-0.5, -0.5, 0], [0.5, -0.5, 0], [0.5, 0.5, 0], [-0.5, 0.5, 0]]
        let normals = [SIMD3<Float>](repeating: [0, 0, 1], count: 4)
        let quadIndex = try geometry.add(attributes: [
            .init(semantic: .position, format: .float3, values: positions),
            .init(semantic: .normal, format: .float3, values: normals)
        ], indices: [0, 1, 2, 0, 2, 3])
        let quad = try geometry.build()[quadIndex]

        let uniforms = PBRMaterialUniforms.defaults(baseColor: [1, 0, 0, 1], metallic: 0, roughness: 0.5)
        let red = try PBRMaterial(uniforms: uniforms, placeholder: PBRMaterial.placeholderBinding(device: device), device: device)

        var builder = PBRModelBuilder(device: device, restPose: PBRPose(worldMatrices: [matrix_identity_float4x4]))
        builder.addInstance(quad, material: red, node: 0)
        let model = try builder.build()

        #expect(model.opaqueBatches.count == 1)
        _ = PBRScene(model: model, viewMatrix: matrix_identity_float4x4, projectionMatrix: matrix_identity_float4x4, lighting: PBRLighting(environment: .studio, toneMapping: .pbrNeutral), showsBackground: true, viewportSize: CGSize(width: 64, height: 64))
    }
}
