import MetalSprocketsPBRShaders

/// How linear radiance, after exposure, becomes display values. Set on ``PBRLighting``.
///
/// All but PBR Neutral follow three.js's operators of the same names, so the three.js reference can match them.
public enum PBRToneMapping: Int32, CaseIterable, Identifiable, Sendable {
    // Same order as PBRShaderToneMapping in PBRShaderTypes.h.
    /// Khronos PBR Neutral: base colors between 0.08 and 0.8 come out unchanged under white light. The default.
    case pbrNeutral
    /// No tone mapping: values are clamped to 0...1.
    case linear
    case acesFilmic
    case agx
    case reinhard
    /// No tone mapping and no clamp: radiance above 1 is kept in float targets (HDR / EDR output). 8-bit targets
    /// clamp it, like `.linear`.
    case none

    public var id: Self { self }

    public var name: String {
        switch self {
        case .pbrNeutral: "PBR Neutral"
        case .linear: "Linear (Clamp)"
        case .acesFilmic: "ACES Filmic"
        case .agx: "AgX"
        case .reinhard: "Reinhard"
        case .none: "None (HDR)"
        }
    }

    public var shaderValue: PBRShaderToneMapping {
        PBRShaderToneMapping(rawValue: rawValue)!
    }
}
