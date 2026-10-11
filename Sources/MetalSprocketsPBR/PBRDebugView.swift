import MetalSprocketsPBRShaders

/// What ``PBRScene`` and ``PBRRenderer`` draw: the lit color, or one shading input for debugging.
///
/// Data views (normals, factors, UVs) show their value directly: 0 is black, 1 is white, and directions map -1...1 to
/// 0...1 per channel. Color views (base color, emissive, F0, sheen) show the color.
public enum PBRDebugView: Int32, CaseIterable, Identifiable, Sendable {
    // Same order as PBRShaderDebugView in PBRShaderTypes.h.
    case lit
    case baseColor
    case alpha
    case metallic
    case roughness
    case occlusion
    case emissive
    /// After normal mapping, world space.
    case shadingNormal
    /// Before normal mapping, world space.
    case geometricNormal
    case tangent
    case bitangent
    /// Green where the tangent frame is right-handed, red where it is mirrored.
    case tangentHandedness
    case texCoord0
    case texCoord1
    /// An 8 x 8 checkerboard over TEXCOORD_0.
    case uvChecker
    /// Green on front faces, red on back faces.
    case frontFacing
    /// Reflectance at normal incidence.
    case specularF0
    case transmission
    case diffuseTransmission
    case clearcoat
    case sheen
    case iridescence

    public var id: Self { self }

    public var name: String {
        switch self {
        case .lit: "Lit"
        case .baseColor: "Base Color"
        case .alpha: "Alpha"
        case .metallic: "Metallic"
        case .roughness: "Roughness"
        case .occlusion: "Occlusion"
        case .emissive: "Emissive"
        case .shadingNormal: "Shading Normal"
        case .geometricNormal: "Geometric Normal"
        case .tangent: "Tangent"
        case .bitangent: "Bitangent"
        case .tangentHandedness: "Tangent Handedness"
        case .texCoord0: "TEXCOORD_0"
        case .texCoord1: "TEXCOORD_1"
        case .uvChecker: "UV Checker"
        case .frontFacing: "Front Facing"
        case .specularF0: "Specular F0"
        case .transmission: "Transmission"
        case .diffuseTransmission: "Diffuse Transmission"
        case .clearcoat: "Clearcoat"
        case .sheen: "Sheen"
        case .iridescence: "Iridescence"
        }
    }

    /// The matching kPBRDebugView* value.
    public var shaderValue: PBRShaderDebugView {
        PBRShaderDebugView(rawValue: rawValue)!
    }
}
