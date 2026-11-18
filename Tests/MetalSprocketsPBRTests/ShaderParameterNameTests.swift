import Foundation
import Metal
@testable import MetalSprocketsPBR
import MetalSprocketsPBRShaders
import Testing

// Parameters are bound by name; a typo or a renamed shader argument would only fail at draw time.
struct ShaderParameterNameTests {
    let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func sources(in directory: String, extension pathExtension: String) throws -> String {
        let url = packageRoot.appending(path: directory)
        let files = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
        return try files.filter { $0.pathExtension == pathExtension }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    // The member names of the struct `fragment_main` takes as `name`, from shader reflection. The frame resources'
    // struct (LightingFrameResources) is defined in MetalSprocketsLighting, not in this package's headers.
    func fragmentStructMembers(_ name: String) throws -> Set<String> {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .metalSprocketsPBRShaders())
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "PBR::vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "PBR::fragment_main")
        descriptor.vertexDescriptor = PBRModel.vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float
        var reflection: MTLRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let binding = try #require(reflection?.fragmentBindings.first { $0.name == name } as? any MTLBufferBinding)
        return Set(try #require(binding.bufferStructType).members.map(\.name))
    }

    // PBRFrameBindings.apply(to:) binds the frame resources' fields one slot at a time for shaders outside this package,
    // so those names count too.
    @Test func everyBoundParameterIsAShaderArgument() throws {
        let swift = try sources(in: "Sources/MetalSprocketsPBR", extension: "swift")
        let metal = try sources(in: "Sources/MetalSprocketsPBRShaders", extension: "metal")
        let frameResourceFields = try fragmentStructMembers("frameResources")
        let names = Set(swift.matches(of: /\.parameter\("(\w+)"/).map { String($0.output.1) })
        #expect(names.count > 10, "Expected to find the renderer's parameters")
        let missing = names.filter { name in
            metal.firstMatch(of: try! Regex("\\b\(name)\\s*\\[\\[")) == nil && !frameResourceFields.contains(name) // swiftlint:disable:this force_try
        }
        #expect(missing.isEmpty, "Bound but not a shader argument: \(missing.sorted())")
    }

    @Test func everyArgumentBufferFieldIsAStructMember() throws {
        let swift = try sources(in: "Sources/MetalSprocketsPBR", extension: "swift")
        let fields = try fragmentStructMembers("frameResources").union(fragmentStructMembers("materialResources"))
        let names = Set(swift.matches(of: /[\s.]set\("(\w+)", (?:texture|textures|samplerState|samplerStates):/).map { String($0.output.1) })
        #expect(names.count == 10, "Expected the LightingFrameResources and PBRMaterialResources fields, found \(names.sorted())")
        #expect(names.subtracting(fields).isEmpty, "Set but not an argument buffer field: \(names.subtracting(fields).sorted())")
    }
}
