// The shader-facing types (PBRVertex, PBRMaterialUniforms, LightingLight, ...) are part of this module's API.
import Metal
@_exported import MetalSprocketsLighting
@_exported import MetalSprocketsPBRShaders
import simd

// @unchecked: MTLTexture and MTLSamplerState are not Sendable. The renderer only reads them, and Metal allows that
// from any thread.

/// A depth shadow map for lights with shadow slices (`LightingLight.shadowSliceStart`, `shadowSliceCount`).
/// Each light's direct light is scaled by the PCF result of its own slices only.
public struct PBRShadows: @unchecked Sendable {
    /// A `depth2d_array` texture: one slice per entry in `sliceViewProjections`.
    public var map: MTLTexture
    /// World to light clip space, one per slice, at most `kLightingMaxShadowSliceCount`.
    public var sliceViewProjections: [simd_float4x4]
    /// PCF half-size in texels.
    public var filterRadius: Int
    /// A comparison sampler; nil uses linear filtering with `lessEqual` (lit when the fragment depth <= the stored depth).
    public var sampler: MTLSamplerState?
    /// 0 leaves shadowed pixels unchanged, 1 fully shadows.
    public var intensity: Float
    /// Linear tint of fully shadowed pixels, like `SCNLight.shadowColor`.
    public var color: SIMD3<Float>

    public init(map: MTLTexture, sliceViewProjections: [simd_float4x4], filterRadius: Int = 1, sampler: MTLSamplerState? = nil, intensity: Float = 1, color: SIMD3<Float> = .zero) {
        self.map = map
        self.sliceViewProjections = sliceViewProjections
        self.filterRadius = filterRadius
        self.sampler = sampler
        self.intensity = intensity
        self.color = color
    }

    var uniforms: LightingShadowUniforms {
        var uniforms = LightingShadowUniforms()
        withUnsafeMutableBytes(of: &uniforms.sliceViewProjections) { buffer in
            let matrices = buffer.bindMemory(to: simd_float4x4.self)
            for (index, matrix) in sliceViewProjections.prefix(matrices.count).enumerated() {
                matrices[index] = matrix
            }
        }
        uniforms.mapSize = Float(map.width)
        uniforms.radius = Int32(filterRadius)
        uniforms.enabled = 1
        uniforms.intensity = intensity
        uniforms.color = color
        return uniforms
    }
}

/// Lights, image-based lighting, exposure and tone mapping for ``PBRRenderer``. There is always an environment.
public struct PBRLighting: Sendable {
    public var lights: [LightingLight]
    public var environment: LightingEnvironment
    public var environmentIntensity: Float
    public var exposure: Float
    public var toneMapping: LightingToneMapping
    /// Turns the environment about +Y, in radians (positive is counter-clockwise seen from above), for lighting and
    /// the background alike.
    public var environmentRotation: Float = 0
    /// Nil: no light is shadowed.
    public var shadows: PBRShadows?
    /// Nil: no screen-space occlusion.
    public var ambientOcclusion: LightingAmbientOcclusion?

    public init(lights: [LightingLight] = [], environment: LightingEnvironment = .studio, environmentIntensity: Float = 1, exposure: Float = 1, toneMapping: LightingToneMapping = .pbrNeutral) {
        self.lights = lights
        self.environment = environment
        self.environmentIntensity = environmentIntensity
        self.exposure = exposure
        self.toneMapping = toneMapping
    }

    /// World directions to environment directions: the inverse of `environmentRotation`.
    public var environmentRotationMatrix: simd_float3x3 {
        Self.environmentRotationMatrix(environmentRotation)
    }

    public static func environmentRotationMatrix(_ angle: Float) -> simd_float3x3 {
        simd_float3x3(simd_quatf(angle: -angle, axis: [0, 1, 0]))
    }

    /// The asset's KHR_lights_punctual lights with the studio environment, placed by `pose` if given.

    /// The studio environment with no punctual lights.
    public static var `default`: Self {
        Self()
    }
}
