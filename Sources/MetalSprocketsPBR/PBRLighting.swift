// The shader-facing types (PBRVertex, PBRMaterialUniforms, PBRLight, ...) are part of this module's API.
import Metal
@_exported import MetalSprocketsPBRShaders
import simd

/// A depth shadow map for lights with shadow slices (``PBRLight/shadowSliceStart``, ``PBRLight/shadowSliceCount``).
/// Each light's direct light is scaled by the PCF result of its own slices only.
public struct PBRShadows: @unchecked Sendable {
    /// A `depth2d_array` texture: one slice per entry in `sliceViewProjections`.
    public var map: MTLTexture
    /// World to light clip space, one per slice, at most `kPBRMaxShadowSliceCount`.
    public var sliceViewProjections: [simd_float4x4]
    /// PCF half-size in texels.
    public var filterRadius: Int
    /// A comparison sampler; nil uses linear filtering with `lessEqual` (lit when the fragment depth <= the stored depth).
    public var sampler: MTLSamplerState?

    public init(map: MTLTexture, sliceViewProjections: [simd_float4x4], filterRadius: Int = 1, sampler: MTLSamplerState? = nil) {
        self.map = map
        self.sliceViewProjections = sliceViewProjections
        self.filterRadius = filterRadius
        self.sampler = sampler
    }

    var uniforms: PBRShadowUniforms {
        var uniforms = PBRShadowUniforms()
        withUnsafeMutableBytes(of: &uniforms.sliceViewProjections) { buffer in
            let matrices = buffer.bindMemory(to: simd_float4x4.self)
            for (index, matrix) in sliceViewProjections.prefix(matrices.count).enumerated() {
                matrices[index] = matrix
            }
        }
        uniforms.mapSize = Float(map.width)
        uniforms.radius = Int32(filterRadius)
        uniforms.enabled = 1
        return uniforms
    }
}

/// Lights, image-based lighting, exposure and tone mapping for ``PBRRenderer``. There is always an environment.
public struct PBRLighting: Sendable {
    public var lights: [PBRLight]
    public var environment: PBREnvironment
    public var environmentIntensity: Float
    public var exposure: Float
    public var toneMapping: PBRToneMapping
    /// Turns the environment about +Y, in radians (positive is counter-clockwise seen from above), for lighting and
    /// the background alike.
    public var environmentRotation: Float = 0
    /// Nil: no light is shadowed.
    public var shadows: PBRShadows?

    public init(lights: [PBRLight] = [], environment: PBREnvironment = .studio, environmentIntensity: Float = 1, exposure: Float = 1, toneMapping: PBRToneMapping = .pbrNeutral) {
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

public extension PBRLight {
    static func directional(direction: SIMD3<Float>, color: SIMD3<Float> = [1, 1, 1], intensity: Float = 1) -> PBRLight {
        var light = PBRLight()
        light.type = .directional
        light.direction = simd_normalize(direction)
        light.color = color
        light.intensity = intensity
        return light
    }

    static func point(position: SIMD3<Float>, color: SIMD3<Float> = [1, 1, 1], intensity: Float = 1, range: Float = 0) -> PBRLight {
        var light = PBRLight()
        light.type = .point
        light.position = position
        light.color = color
        light.intensity = intensity
        light.range = range
        return light
    }
}
