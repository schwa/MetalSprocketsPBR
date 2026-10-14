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

    @Test func everyBoundParameterIsAShaderArgument() throws {
        let swift = try sources(in: "Sources/MetalSprocketsPBR", extension: "swift")
        let metal = try sources(in: "Sources/MetalSprocketsPBRShaders", extension: "metal")
        let names = Set(swift.matches(of: /\.parameter\("(\w+)"/).map { String($0.output.1) })
        #expect(names.count > 10, "Expected to find the renderer's parameters")
        let missing = names.filter { name in
            metal.firstMatch(of: try! Regex("\\b\(name)\\s*\\[\\[")) == nil // swiftlint:disable:this force_try
        }
        #expect(missing.isEmpty, "Bound but not a shader argument: \(missing.sorted())")
    }
}
