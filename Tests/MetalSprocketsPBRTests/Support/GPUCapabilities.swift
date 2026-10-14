import Metal
import Testing

// GitHub Actions' paravirtual GPU has no Metal 4 support; Buildkite runs these on real hardware.
let supportsMetal4: Bool = MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) ?? false

extension Trait where Self == ConditionTrait {
    static var requiresMetal4: Self {
        .disabled(if: !supportsMetal4, "Needs a Metal 4 GPU")
    }
}
