import Metal
import MetalSprockets
import MetalSprocketsPBRShaders
import simd

public extension PBRMaterialUniforms {
    /// Every texture slot's uniforms, in `PBRMaterialTextureIndex` order.
    static var textureSlots: [WritableKeyPath<PBRMaterialUniforms, PBRTextureSlot>] {
        [
            \.baseColor, \.metallicRoughness, \.normal, \.occlusion, \.emissive, \.transmission, \.thickness, \.specular,
            \.specularColor, \.iridescence, \.iridescenceThickness, \.anisotropy, \.sheenColor, \.sheenRoughness,
            \.clearcoat, \.clearcoatRoughness, \.clearcoatNormal, \.diffuseTransmission, \.diffuseTransmissionColor,
            \.retroreflection
        ]
    }

    /// glTF's defaults (and each material extension's when absent): opaque, no textures, no transmission, a thin
    /// non-absorbing volume, full specular, no clearcoat, sheen or iridescence. Base color, metallic and roughness
    /// default as in glTF (white, 1, 1); a code-built material usually sets them.
    static func defaults(baseColor: SIMD4<Float> = [1, 1, 1, 1], metallic: Float = 1, roughness: Float = 1) -> Self {
        var uniforms = Self()
        uniforms.baseColorFactor = baseColor
        uniforms.metallicFactor = metallic
        uniforms.roughnessFactor = roughness
        uniforms.emissiveFactor = .zero
        uniforms.emissiveStrength = 1
        uniforms.ior = 1.5
        uniforms.normalScale = 1
        uniforms.occlusionStrength = 1
        uniforms.alphaCutoff = 0.5
        uniforms.alphaMode = .opaque
        for slot in textureSlots {
            uniforms[keyPath: slot].transform = matrix_identity_float3x3
            uniforms[keyPath: slot].enabled = 0
        }
        uniforms.attenuationDistance = .infinity
        uniforms.attenuationColor = [1, 1, 1]
        uniforms.specularFactor = 1
        uniforms.specularColorFactor = [1, 1, 1]
        uniforms.iridescenceIor = 1.3
        uniforms.iridescenceThicknessMinimum = 100
        uniforms.iridescenceThicknessMaximum = 400
        uniforms.diffuseTransmissionColorFactor = [1, 1, 1]
        uniforms.clearcoatNormalScale = 1
        return uniforms
    }
}

/// A PBR material resolved into shader uniforms, textures and samplers.
///
/// Immutable, so a render thread can draw with it while other threads read it. To change a live material, set
/// ``PBRPose/materialUniforms`` each frame, or draw a copy made with ``with(uniforms:renderState:textureTransforms:)``
/// through ``PBRModel/MaterialOverrides``.
public final class PBRMaterial: @unchecked Sendable {
    public struct Binding {
        public let texture: MTLTexture
        public let sampler: MTLSamplerState
        // Kept because MTLSamplerState cannot be read back (e.g. to save filters and address modes).
        public let samplerDescriptor: MTLSamplerDescriptor

        public init(texture: MTLTexture, samplerDescriptor: MTLSamplerDescriptor, device: MTLDevice) throws {
            // swiftlint:disable:next force_cast
            let descriptor = samplerDescriptor.copy() as! MTLSamplerDescriptor
            descriptor.supportArgumentBuffers = true
            guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
                throw PBRGeometryError.bufferAllocationFailed
            }
            self.texture = texture
            self.sampler = sampler
            self.samplerDescriptor = descriptor
        }
    }

    /// A texture slot's UV transform split into parts (offset, rotation, scale), so animation can change one part.
    public struct TextureTransform {
        public var slot: WritableKeyPath<PBRMaterialUniforms, PBRTextureSlot>
        public var offset: SIMD2<Float>
        public var rotation: Float
        public var scale: SIMD2<Float>

        public init(slot: WritableKeyPath<PBRMaterialUniforms, PBRTextureSlot>, offset: SIMD2<Float> = .zero, rotation: Float = 0, scale: SIMD2<Float> = [1, 1]) {
            self.slot = slot
            self.offset = offset
            self.rotation = rotation
            self.scale = scale
        }

        /// uv' = T * R * S * uv.
        public var matrix: simd_float3x3 {
            let translation = simd_float3x3(columns: ([1, 0, 0], [0, 1, 0], [offset.x, offset.y, 1]))
            let rotation = simd_float3x3(columns: ([cos(self.rotation), -sin(self.rotation), 0], [sin(self.rotation), cos(self.rotation), 0], [0, 0, 1]))
            let scale = simd_float3x3(diagonal: [self.scale.x, self.scale.y, 1])
            return translation * rotation * scale
        }
    }

    public let name: String?
    public let uniforms: PBRMaterialUniforms
    public let doubleSided: Bool
    /// Decides which batches merge and which are blended.
    public let renderState: PBRRenderState
    /// Every material texture and its sampler, in `PBRMaterialTextureIndex` order. Slots the material does not use
    /// hold a placeholder (see ``placeholderBinding(device:)``).
    public let textureBindings: [Binding]
    /// `textureBindings` as a `PBRMaterialResources` argument buffer, so a draw binds the whole material with one
    /// buffer and keeps its textures resident.
    public let resources: ArgumentBuffer
    /// Animatable texture transforms, keyed by the producer's name for the texture (glTF: its path below
    /// `/materials/N/`).
    public let textureTransforms: [String: TextureTransform]

    public subscript(texture index: PBRMaterialTextureIndex) -> Binding {
        textureBindings[Int(index.rawValue)]
    }

    public var isBlended: Bool { renderState.resolvedBlendMode(alphaMode: uniforms.alphaMode) != .opaque }
    public var isTransmissive: Bool { uniforms.transmissionFactor > 0 }

    /// Whether `other` can be drawn in place of this material without rebuilding the model: it is drawn in the same
    /// passes (``PBRModel/MaterialOverrides``).
    public func canOverride(_ other: PBRMaterial) -> Bool {
        isBlended == other.isBlended && isTransmissive == other.isTransmissive && renderState.isDefault == other.renderState.isDefault
    }

    /// `textureBindings` must have one binding per `PBRMaterialTextureIndex` (`kPBRMaterialTextureCount`); enable
    /// the matching `uniforms` slots for the ones that are real textures.
    public init(name: String? = nil, uniforms: PBRMaterialUniforms, doubleSided: Bool = false, renderState: PBRRenderState = PBRRenderState(), textureTransforms: [String: TextureTransform] = [:], textureBindings: [Binding], device: MTLDevice) {
        precondition(textureBindings.count == Int(kPBRMaterialTextureCount.rawValue), "One texture binding per PBRMaterialTextureIndex")
        self.name = name
        self.uniforms = uniforms
        self.doubleSided = doubleSided
        self.renderState = renderState
        self.textureTransforms = textureTransforms
        self.textureBindings = textureBindings
        resources = ArgumentBuffer(device: device, label: "\(name ?? "PBR Material") Resources")
        resources.setMaterialResources(textureBindings)
    }

    /// A material with every texture slot holding `placeholder` (disabled in the uniforms): factors only.
    public convenience init(name: String? = nil, uniforms: PBRMaterialUniforms, doubleSided: Bool = false, renderState: PBRRenderState = PBRRenderState(), placeholder: Binding, device: MTLDevice) {
        self.init(name: name, uniforms: uniforms, doubleSided: doubleSided, renderState: renderState, textureBindings: Array(repeating: placeholder, count: Int(kPBRMaterialTextureCount.rawValue)), device: device)
    }

    private init(copying material: PBRMaterial, uniforms: PBRMaterialUniforms, renderState: PBRRenderState, textureTransforms: [String: TextureTransform]) {
        name = material.name
        self.uniforms = uniforms
        doubleSided = material.doubleSided
        self.renderState = renderState
        self.textureTransforms = textureTransforms
        textureBindings = material.textureBindings
        resources = material.resources
    }

    /// A new material sharing this one's textures and GPU resources, with the given values replaced.
    public func with(uniforms: PBRMaterialUniforms? = nil, renderState: PBRRenderState? = nil, textureTransforms: [String: TextureTransform]? = nil) -> PBRMaterial {
        PBRMaterial(copying: self, uniforms: uniforms ?? self.uniforms, renderState: renderState ?? self.renderState, textureTransforms: textureTransforms ?? self.textureTransforms)
    }

    /// A 1x1 white texture with a repeating linear sampler, for unused texture slots.
    public static func placeholderBinding(device: MTLDevice) throws -> Binding {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PBRGeometryError.bufferAllocationFailed
        }
        texture.label = "PBR Placeholder"
        let white: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: white, bytesPerRow: 4)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        return try Binding(texture: texture, samplerDescriptor: samplerDescriptor, device: device)
    }
}

extension ArgumentBuffer {
    // One `PBRMaterialResources` element, in `PBRMaterialTextureIndex` order.
    func setMaterialResources(_ bindings: [PBRMaterial.Binding], element: Int = 0) {
        set("textures", textures: bindings.map(\.texture), element: element)
        set("samplers", samplerStates: bindings.map(\.sampler), element: element)
    }
}
