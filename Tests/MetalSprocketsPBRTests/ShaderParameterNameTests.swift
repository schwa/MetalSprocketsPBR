import Foundation
import Testing

// Parameters are bound by name; a typo or a renamed shader argument would only fail at draw time.
struct ShaderParameterNameTests {
    let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func sources(in directory: String, extension pathExtension: String) throws -> String {
        let url = packageRoot.appending(path: directory)
        let files = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
        return try files.filter { $0.pathExtension == pathExtension }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    // Also counts fields of argument-buffer structs, such as PBRFrameResources: PBRFrameBindings.apply(to:) binds those
    // names one slot at a time for shaders outside this package.
    @Test func everyBoundParameterIsAShaderArgument() throws {
        let swift = try sources(in: "Sources/MetalSprocketsPBR", extension: "swift")
        let metal = try sources(in: "Sources/MetalSprocketsPBRShaders", extension: "metal")
        let headers = try sources(in: "Sources/MetalSprocketsPBRShaders", extension: "h")
        let names = Set(swift.matches(of: /\.parameter\("(\w+)"/).map { String($0.output.1) })
        #expect(names.count > 10, "Expected to find the renderer's parameters")
        let missing = names.filter { name in
            metal.firstMatch(of: try! Regex("\\b\(name)\\s*\\[\\[")) == nil && headers.firstMatch(of: try! Regex("\\b\(name);")) == nil // swiftlint:disable:this force_try
        }
        #expect(missing.isEmpty, "Bound but not a shader argument: \(missing.sorted())")
    }

    @Test func everyArgumentBufferFieldIsAStructMember() throws {
        let swift = try sources(in: "Sources/MetalSprocketsPBR", extension: "swift")
        let headers = try sources(in: "Sources/MetalSprocketsPBRShaders", extension: "h")
        let names = Set(swift.matches(of: /[\s.]set\("(\w+)", (?:texture|textures|samplerState|samplerStates):/).map { String($0.output.1) })
        #expect(names.count == 10, "Expected the PBRFrameResources and PBRMaterialResources fields, found \(names.sorted())")
        let missing = names.filter { name in
            headers.firstMatch(of: try! Regex("\\b\(name);")) == nil // swiftlint:disable:this force_try
        }
        #expect(missing.isEmpty, "Set but not an argument buffer field: \(missing.sorted())")
    }
}
