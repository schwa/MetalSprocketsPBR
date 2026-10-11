import MetalSprocketsPBRShaders
import simd

/// Node transforms, morph weights and visibility at one moment, all indexed by node, plus animated lights and camera
/// properties.
public struct PBRPose: Sendable {
    public var worldMatrices: [simd_float4x4]
    /// Morph target weights for each node's mesh (empty for nodes without morph targets).
    public var morphWeights: [[Float]]
    /// Shader uniforms for materials that animation changes, keyed by the material's identity.
    public var materialUniforms: [ObjectIdentifier: PBRMaterialUniforms] = [:]
    /// Whether each node is drawn, after its ancestors' visibility; empty means every node is. Hidden nodes' instances
    /// are not drawn.
    public var visibility: [Bool] = []
    /// The lights at this moment (placed, animated, without hidden ones), when the producer computed them; nil uses the
    /// model's lights.
    public var lights: [PBRLight]?
    /// Animated camera properties, by camera index then the producer's property name (glTF: the JSON pointer below
    /// `/cameras/N/`, e.g. `perspective/yfov`).
    public var cameraParameters: [Int: [String: Float]] = [:]

    public init(worldMatrices: [simd_float4x4], morphWeights: [[Float]] = [], materialUniforms: [ObjectIdentifier: PBRMaterialUniforms] = [:], visibility: [Bool] = []) {
        self.worldMatrices = worldMatrices
        self.morphWeights = morphWeights
        self.materialUniforms = materialUniforms
        self.visibility = visibility
    }

    /// Whether node `index` is drawn.
    public func isVisible(_ index: Int) -> Bool {
        visibility.isEmpty || !visibility.indices.contains(index) || visibility[index]
    }

    /// Whether any node is hidden.
    public var hidesNodes: Bool {
        visibility.contains(false)
    }
}
