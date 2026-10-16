#pragma once

#import "MetalSprocketsShaders.h"
#import <simd/simd.h>

// Interleaved vertex stored in vertex buffer 0. Attribute indices match the order of fields.
struct PBRVertex {
    simd_float3 position;
    simd_float3 normal;
    simd_float4 tangent; // xyz + handedness in w. Zero when the primitive has no tangents.
    simd_float2 texCoord0;
    simd_float2 texCoord1;
    simd_float4 color; // COLOR_0, or white when absent.
};
typedef struct PBRVertex PBRVertex;

// Skinning inputs for skinned primitives, stored in their own vertex buffer (GLTFAsset.skinBufferIndex). Joint indices index the skin's joint list.
struct PBRSkinVertex {
    simd_float4 joints;
    simd_float4 weights;
};
typedef struct PBRSkinVertex PBRSkinVertex;

// One vertex's offsets for one morph target. A primitive's deltas are stored target-major: [target][vertex].
struct PBRMorphDelta {
    simd_float3 position;
    simd_float3 normal;
    simd_float3 tangent; // xyz only; the handedness in w is not morphed.
};
typedef struct PBRMorphDelta PBRMorphDelta;

struct PBRMorphUniforms {
    unsigned int targetCount; // 0 when the primitive has no morph targets.
    unsigned int vertexCount;
};
typedef struct PBRMorphUniforms PBRMorphUniforms;

// One placement of a primitive in the scene. Instanced draws read an array of these.
struct PBRInstance {
    simd_float4x4 worldMatrix;
    simd_float4x4 normalMatrix; // Inverse transpose of worldMatrix. Only the upper 3x3 is used.
};
typedef struct PBRInstance PBRInstance;

// Views drawn at once: 1, or 2 for stereo (visionOS), where vertex amplification draws each primitive once per eye
// and [[amplification_id]] picks the eye's entry in the per-view arrays below. With one view, entry 0 is used.
#define kPBRMaxViewCount 2

// Per-frame vertex inputs shared by every draw.
struct PBRViewUniforms {
    simd_float4x4 viewProjectionMatrices[kPBRMaxViewCount];
    simd_float4x4 modelMatrix;       // Applied on top of every instance's worldMatrix.
    simd_float4x4 modelNormalMatrix; // Inverse transpose of modelMatrix.
};
typedef struct PBRViewUniforms PBRViewUniforms;

typedef MS_ENUM(int, PBRAlphaMode) {
    kPBRAlphaModeOpaque = 0,
    kPBRAlphaModeMask = 1,
    kPBRAlphaModeBlend = 2,
};

// Per-texture UV set index and KHR_texture_transform matrix.
struct PBRTextureSlot {
    simd_float3x3 transform;
    int texCoord;
    int enabled;
};
typedef struct PBRTextureSlot PBRTextureSlot;

struct PBRMaterialUniforms {
    simd_float4 baseColorFactor;
    simd_float3 emissiveFactor;
    float metallicFactor;
    float roughnessFactor;
    float normalScale;
    float occlusionStrength;
    float alphaCutoff;
    float emissiveStrength;
    PBRAlphaMode alphaMode;
    int unlit;
    int hasTangents;
    int hasNormals; // 0: derive flat normals from screen-space derivatives.
    int isPointOrLine; // Not triangles: no barycentrics, so no wireframe.
    PBRTextureSlot baseColor;
    PBRTextureSlot metallicRoughness;
    PBRTextureSlot normal;
    PBRTextureSlot occlusion;
    PBRTextureSlot emissive;
    // KHR_materials_transmission
    float transmissionFactor;
    PBRTextureSlot transmission;
    // KHR_materials_volume
    float thicknessFactor;
    float attenuationDistance; // INFINITY when the volume does not absorb.
    simd_float3 attenuationColor;
    PBRTextureSlot thickness;
    // KHR_materials_ior
    float ior;
    // KHR_materials_specular
    float specularFactor;
    simd_float3 specularColorFactor;
    PBRTextureSlot specular;      // Strength in alpha.
    PBRTextureSlot specularColor; // sRGB color.
    // KHR_materials_iridescence
    float iridescenceFactor;
    float iridescenceIor;
    float iridescenceThicknessMinimum; // Nanometers.
    float iridescenceThicknessMaximum;
    PBRTextureSlot iridescence;          // Factor in red.
    PBRTextureSlot iridescenceThickness; // Blend from minimum to maximum in green.
    // KHR_materials_anisotropy
    float anisotropyStrength;
    float anisotropyRotation; // Radians.
    PBRTextureSlot anisotropy; // Direction in red/green, strength in blue.
    // KHR_materials_sheen
    simd_float3 sheenColorFactor; // Zero disables sheen.
    float sheenRoughnessFactor;
    PBRTextureSlot sheenColor;     // sRGB color.
    PBRTextureSlot sheenRoughness; // Roughness in alpha.
    // KHR_materials_clearcoat
    float clearcoatFactor;
    float clearcoatRoughnessFactor;
    float clearcoatNormalScale;
    PBRTextureSlot clearcoat;          // Factor in red.
    PBRTextureSlot clearcoatRoughness; // Roughness in green.
    PBRTextureSlot clearcoatNormal;
    // KHR_materials_dispersion
    float dispersion;
    // KHR_materials_diffuse_transmission
    float diffuseTransmissionFactor; // Zero disables diffuse transmission.
    simd_float3 diffuseTransmissionColorFactor;
    PBRTextureSlot diffuseTransmission;      // Factor in alpha.
    PBRTextureSlot diffuseTransmissionColor; // sRGB color.
    // KHR_materials_retroreflection: blend from the regular to the retroreflective specular lobes (zero disables).
    float retroreflectionFactor;
    PBRTextureSlot retroreflection; // Multiplier in red.
    // KHR_materials_volume_scatter, approximated: light scattered in the volume comes back out tinted by the
    // multiscatter color, half on the lit side (as diffuse reflection) and half through to the far side.
    int volumeScatter;
    simd_float3 multiscatterColorFactor;
    // KHR_materials_pbrSpecularGlossiness, mapped onto the fields above: diffuse is the base color (metallic 0) and
    // specular is specularColor. Roughness is 1 - glossinessFactor * the specularColor texture's alpha.
    int specularGlossiness;
    float glossinessFactor;
};
typedef struct PBRMaterialUniforms PBRMaterialUniforms;

/// Indices into `PBRMaterialResources`, one per material texture.
enum PBRMaterialTextureIndex {
    kPBRTextureBaseColor = 0,
    kPBRTextureMetallicRoughness,
    kPBRTextureNormal,
    kPBRTextureOcclusion,
    kPBRTextureEmissive,
    kPBRTextureTransmission,
    kPBRTextureThickness,
    kPBRTextureSpecular,
    kPBRTextureSpecularColor,
    kPBRTextureIridescence,
    kPBRTextureIridescenceThickness,
    kPBRTextureAnisotropy,
    kPBRTextureSheenColor,
    kPBRTextureSheenRoughness,
    kPBRTextureClearcoat,
    kPBRTextureClearcoatRoughness,
    kPBRTextureClearcoatNormal,
    kPBRTextureDiffuseTransmission,
    kPBRTextureDiffuseTransmissionColor,
    kPBRTextureRetroreflection,
    kPBRMaterialTextureCount
};

/// A material's textures and samplers in one argument buffer, so a draw binds them with one buffer.
/// On the CPU each entry is the resource's `gpuResourceID`.
struct PBRMaterialResources {
#ifdef __METAL_VERSION__
    metal::array<metal::texture2d<float>, kPBRMaterialTextureCount> textures;
    metal::array<metal::sampler, kPBRMaterialTextureCount> samplers;
#else
    uint64_t textures[kPBRMaterialTextureCount];
    uint64_t samplers[kPBRMaterialTextureCount];
#endif
};

typedef MS_ENUM(int, PBRLightType) {
    kPBRLightTypeDirectional = 0,
    kPBRLightTypePoint = 1,
    kPBRLightTypeSpot = 2,
};

struct PBRLight {
    simd_float3 position;
    simd_float3 direction; // Direction the light travels, in world space.
    simd_float3 color;
    float intensity;
    float range; // 0 means infinite.
    float innerConeCos;
    float outerConeCos;
    PBRLightType type;
    // This light's slices in the shadow map; count 0 casts no shadow. Each slice's PCF result scales only this light.
    int shadowSliceStart;
    int shadowSliceCount;
};
typedef struct PBRLight PBRLight;

#define kPBRMaxShadowSliceCount 8

// The shadow map shared by every light with shadow slices.
struct PBRShadowUniforms {
    // World to light clip space, one per slice. Depth is compared in 0...1 with the shadow sampler's compare function.
    simd_float4x4 sliceViewProjections[kPBRMaxShadowSliceCount];
    float mapSize;
    int radius; // PCF half-size in texels.
    int enabled;
    float intensity; // 0 leaves shadowed pixels unchanged, 1 fully shadows.
    simd_float3 color; // Tint of fully shadowed pixels.
};
typedef struct PBRShadowUniforms PBRShadowUniforms;

/// How linear radiance (after exposure) becomes display values. Mirrored by the Swift PBRToneMapping; 0 is the default.
typedef MS_ENUM(int, PBRShaderToneMapping) {
    kPBRToneMappingPBRNeutral = 0, // Khronos PBR Neutral.
    kPBRToneMappingLinear,         // Clamp to 0...1 (three.js LinearToneMapping).
    kPBRToneMappingACESFilmic,     // three.js ACESFilmicToneMapping.
    kPBRToneMappingAgX,            // three.js AgXToneMapping.
    kPBRToneMappingReinhard,       // three.js ReinhardToneMapping.
    kPBRToneMappingNone,           // Unbounded linear output for HDR targets (three.js NoToneMapping).
    kPBRToneMappingCount
};

/// What the PBR shader outputs: the lit color, or one of its inputs for debugging. Mirrored by the Swift PBRDebugView.
typedef MS_ENUM(int, PBRShaderDebugView) {
    kPBRDebugViewLit = 0,
    kPBRDebugViewBaseColor,
    kPBRDebugViewAlpha,
    kPBRDebugViewMetallic,
    kPBRDebugViewRoughness,
    kPBRDebugViewOcclusion,
    kPBRDebugViewEmissive,
    kPBRDebugViewShadingNormal,     // After normal mapping, world space.
    kPBRDebugViewGeometricNormal,   // Before normal mapping, world space.
    kPBRDebugViewTangent,
    kPBRDebugViewBitangent,
    kPBRDebugViewTangentHandedness, // Green: tangent frame right-handed; red: mirrored.
    kPBRDebugViewTexCoord0,
    kPBRDebugViewTexCoord1,
    kPBRDebugViewUVChecker,         // 8 x 8 checkerboard over TEXCOORD_0.
    kPBRDebugViewFrontFacing,       // Green: front face; red: back face.
    kPBRDebugViewSpecularF0,        // Reflectance at normal incidence.
    kPBRDebugViewTransmission,
    kPBRDebugViewDiffuseTransmission,
    kPBRDebugViewClearcoat,
    kPBRDebugViewSheen,
    kPBRDebugViewIridescence,
    kPBRDebugViewCount
};

struct PBRFrameUniforms {
    simd_float3 cameraPositions[kPBRMaxViewCount];
    int lightCount;
    float exposure;
    float environmentIntensity;
    float specularMipCount;
    // Screen-space transmission: the opaque scene behind transmissive surfaces, and how to project into it.
    simd_float4x4 viewProjectionMatrices[kPBRMaxViewCount];
    int hasTransmissionScene;
    float transmissionSceneMipCount;
    // No transmission scene and the target is blended over what is behind (visionOS passthrough): transmissive
    // surfaces refract nothing and write premultiplied color with alpha = 1 - the light they let through, so blending
    // shows what is behind them.
    int transmissionAsCoverage;
    // Write linear HDR radiance (no exposure or tone mapping), for the transmission pre-pass.
    int linearOutput;
    PBRShaderDebugView debugView;
    int showsWireframe; // Draw triangle edges over the output.
    PBRShaderToneMapping toneMapping;
    // World direction to environment direction (the inverse of the environment's rotation). Zero means identity.
    simd_float3x3 environmentRotation;
};
typedef struct PBRFrameUniforms PBRFrameUniforms;

struct PBRPrefilterParameters {
    float roughness;
    unsigned int sampleCount;
};
typedef struct PBRPrefilterParameters PBRPrefilterParameters;

struct PBRBackgroundUniforms {
    simd_float4x4 inverseViewProjections[kPBRMaxViewCount]; // Per view: projection times view without translation, inverted.
    float lod;
    float intensity;
    float exposure;
    int linearOutput; // Skip exposure and tone mapping, for the transmission pre-pass.
    PBRShaderToneMapping toneMapping;
    simd_float3x3 environmentRotation; // As in PBRFrameUniforms.
};
typedef struct PBRBackgroundUniforms PBRBackgroundUniforms;
