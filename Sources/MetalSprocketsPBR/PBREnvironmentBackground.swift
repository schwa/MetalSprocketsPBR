import Metal
import MetalSprockets
import MetalSprocketsPBRShaders
import simd

/// Draws a ``PBREnvironment`` behind the scene. Place it before ``PBRRenderer`` in the same `RenderPass`.
///
/// Uses the same exposure and tone mapping as `PBRRenderer`, so reflections match the background.
public struct PBREnvironmentBackground: Element {
    public var environment: PBREnvironment
    public var viewMatrix: simd_float4x4
    public var projectionMatrix: simd_float4x4
    public var intensity: Float
    public var exposure: Float
    public var toneMapping: PBRToneMapping = .pbrNeutral
    /// As ``PBRLighting/environmentRotation``.
    public var rotation: Float = 0
    /// 0 is sharp; 1 samples the smallest mip of the source.
    public var blur: Float
    /// Write linear HDR radiance without exposure or tone mapping (for ``PBRTransmissionPass``).
    var linearOutput = false
    /// Draw these views at once instead of `viewMatrix` and `projectionMatrix` (see ``PBRRenderer/stereo``).
    public var stereo: PBRStereoViews?

    public init(environment: PBREnvironment, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, intensity: Float = 1, exposure: Float = 1, blur: Float = 0) {
        self.environment = environment
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.intensity = intensity
        self.exposure = exposure
        self.blur = blur
    }

    /// Takes the environment, intensity, exposure and tone mapping from `lighting`.
    public init(lighting: PBRLighting, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, blur: Float = 0) {
        self.init(environment: lighting.environment, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, intensity: lighting.environmentIntensity, exposure: lighting.exposure, blur: blur)
        toneMapping = lighting.toneMapping
        rotation = lighting.environmentRotation
    }

    public var body: some Element {
        get throws {
            try content()
        }
    }

    func content() throws -> some Element {
        let shaders = try PBRShaders.shared()
        let inverseViewProjections = zip(stereo?.projectionMatrices ?? [projectionMatrix], stereo?.viewMatrices ?? [viewMatrix]).map { projection, view in
            var rotationOnly = view
            rotationOnly.columns.3 = [0, 0, 0, 1]
            return (projection * rotationOnly).inverse
        }
        let stereo = stereo
        let uniforms = PBRBackgroundUniforms(
            inverseViewProjections: viewPair(inverseViewProjections),
            lod: blur * Float(environment.source.mipmapLevelCount - 1),
            intensity: intensity,
            exposure: exposure,
            linearOutput: linearOutput ? 1 : 0,
            toneMapping: toneMapping.shaderValue,
            environmentRotation: PBRLighting.environmentRotationMatrix(rotation)
        )
        let source = environment.source
        return try RenderPipeline(label: "PBR Environment Background", vertexShader: shaders.backgroundVertex, fragmentShader: shaders.backgroundFragment) {
            Draw { encoder in
                stereo?.configure(encoder)
                encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            }
            .parameter("uniforms", value: uniforms)
            .parameter("environment", texture: source)
        }
        .depthCompare(function: .always, enabled: false)
    }
}
