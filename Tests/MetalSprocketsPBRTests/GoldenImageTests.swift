import CoreGraphics
import Foundation
import GoldenImage
import Metal
import MetalSprockets
import MetalSprocketsPBR
import simd
import SwiftMesh
import Testing

// Renders scenes built in code and compares them against stored golden images.
//
// To add or update a golden: delete it, run the tests, and copy the image named in the failure from the output
// directory into Tests/MetalSprocketsPBRTests/GoldenImages. MaterialSpheres.png is also the README screenshot.

@Suite(.requiresMetal4, .serialized)
@MainActor
struct GoldenImageTests {
    // Exact match: renders are bit-identical across runs on the machine that recorded the goldens (Apple silicon).
    // Other GPUs or driver versions may need the goldens re-recorded.
    static let psnrThreshold = 120.0
    static let outputDirectory = FileManager.default.temporaryDirectory.appending(path: "MetalSprocketsPBR-GoldenImages")

    let device = MTLCreateSystemDefaultDevice()!

    @Test
    func readmeQuad() throws {
        // The README's Usage example.
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
        try check("ReadmeQuad", model: builder.build(), size: CGSize(width: 256, height: 256))
    }

    @Test
    func materialSpheres() throws {
        try check("MaterialSpheres", model: Self.spheres(device: device), size: CGSize(width: 768, height: 512), yaw: 0, pitch: 0, distanceScale: 0.75)
    }

    /// A grid of spheres: metallic 0 and 1 by row pairs, roughness from 0 to 1 across.
    static func spheres(device: MTLDevice) throws -> PBRModel {
        var geometry = PBRGeometryBuilder(device: device)
        let sphere = try geometry.add(MetalMesh(mesh: .sphere(extents: [0.9, 0.9, 0.9], latitudeSegments: 32, longitudeSegments: 64, attributes: [.smoothNormals, .textureCoordinates]), device: device))[0]
        let primitive = try geometry.build()[sphere]
        let placeholder = try PBRMaterial.placeholderBinding(device: device)
        let columns = 6
        let rows = 3
        var matrices: [simd_float4x4] = []
        var materials: [PBRMaterial] = []
        let colors: [SIMD4<Float>] = [[0.9, 0.1, 0.1, 1], [1, 0.78, 0.35, 1], [0.95, 0.95, 0.95, 1]]
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let roughness = Float(column) / Float(columns - 1)
                let metallic: Float = row == 0 ? 0 : 1
                let uniforms = PBRMaterialUniforms.defaults(baseColor: colors[row], metallic: metallic, roughness: roughness)
                materials.append(try PBRMaterial(uniforms: uniforms, placeholder: placeholder, device: device))
                matrices.append(simd_float4x4(translation: [Float(column) - Float(columns - 1) / 2, Float(rows - 1) / 2 - Float(row), 0]))
            }
        }
        var builder = PBRModelBuilder(device: device, restPose: PBRPose(worldMatrices: matrices))
        for (node, material) in materials.enumerated() {
            builder.addInstance(primitive, material: material, node: node)
        }
        return try builder.build()
    }

    func check(_ name: String, model: PBRModel, size: CGSize, yaw: Float = .pi / 6, pitch: Float = -.pi / 8, distanceScale: Float = 1) throws {
        let aspectRatio = Float(size.width / size.height)
        let camera = PBRCamera.framing(model.bounds, aspectRatio: aspectRatio, yaw: yaw, pitch: pitch, distanceScale: distanceScale)
        let scene = PBRScene(model: model, viewMatrix: camera.viewMatrix, projectionMatrix: camera.projectionMatrix, lighting: PBRLighting(environment: .studio), showsBackground: true, viewportSize: size)
        let image = try OffscreenRenderer(size: size, clearDepth: 0).render(scene).cgImage
        let goldens = try #require(Bundle.module.url(forResource: "GoldenImages", withExtension: nil))
        let comparison = GoldenImageComparison(imageDirectory: goldens, psnrThreshold: Self.psnrThreshold, failureOutputDirectory: Self.outputDirectory)
        do {
            if try !comparison.image(image: image, matchesGoldenImageNamed: name) {
                Issue.record("\(name) does not match its golden image. Rendered images are in \(Self.outputDirectory.path).")
            }
        } catch GoldenImageError.noGoldenImage(let savedTo) {
            Issue.record("No golden image for \(name). Rendered image saved to \(savedTo?.path ?? "nowhere").")
        }
    }
}
