#include "MetalSprocketsPBRShaders.h"
#include "PBRShaderSupport.h"

// glTF 2.0 metallic-roughness BRDF. See the glTF spec, Appendix B.
// https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#appendix-b-brdf-implementation

using namespace metal;
using namespace PBRSupport;

namespace PBR {

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float4 tangent [[attribute(2)]];
        float2 texCoord0 [[attribute(3)]];
        float2 texCoord1 [[attribute(4)]];
        float4 color [[attribute(5)]];
    };

    struct SkinnedVertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float4 tangent [[attribute(2)]];
        float2 texCoord0 [[attribute(3)]];
        float2 texCoord1 [[attribute(4)]];
        float4 color [[attribute(5)]];
        float4 joints [[attribute(6)]];
        float4 weights [[attribute(7)]];
    };

    struct Fragment {
        float4 position [[position]];
        float3 worldPosition;
        float3 normal;
        float4 tangent;
        float2 texCoord0;
        float2 texCoord1;
        float4 color;
        float modelScale; // Average axis scale of the model matrix, for volume thickness.
        float pointSize [[point_size]]; // Required when drawing point primitives.
        uint record [[flat]]; // Draw record of merged static geometry; unused otherwise.
        uint eye [[flat]]; // Which view (amplification ID) this is drawn for; selects the per-view uniforms.
    };

    float3x3 upperLeft(float4x4 matrix) {
        return float3x3(matrix[0].xyz, matrix[1].xyz, matrix[2].xyz);
    }

    Fragment makeFragment(float3 position, float3 normal, float4 tangent, float2 texCoord0, float2 texCoord1, float4 color, constant PBRViewUniforms &view, ushort eye, float4x4 modelMatrix, float3x3 normalMatrix);
    void applyMorph(thread float3 &position, thread float3 &normal, thread float4 &tangent, uint vertexID, constant PBRMorphUniforms &morph, constant PBRMorphDelta *deltas, constant float *weights);

    Fragment instancedFragment(VertexIn in, float3 position, float3 normal, float4 tangent, PBRInstance instance, constant PBRViewUniforms &view, ushort eye) {
        return makeFragment(position, normal, tangent, in.texCoord0, in.texCoord1, in.color, view, eye, view.modelMatrix * instance.worldMatrix, upperLeft(instance.normalMatrix));
    }

    Fragment skinnedFragment(SkinnedVertexIn in, float3 position, float3 normal, float4 tangent, constant float4x4 *jointMatrices, constant PBRViewUniforms &view, ushort eye);

    // Primitives without morph targets use the variants without morph arguments, so their draws bind nothing for them.

    [[vertex]] Fragment vertex_main(
        VertexIn in [[stage_in]],
        uint instanceID [[instance_id]],
        ushort eye [[amplification_id]],
        constant PBRViewUniforms &view [[buffer(1)]],
        constant PBRInstance *instances [[buffer(2)]]
    ) {
        return instancedFragment(in, in.position, in.normal, in.tangent, instances[instanceID], view, eye);
    }

    // Merged static geometry: one instance buffer for every record, plus each instance's record index.
    [[vertex]] Fragment vertex_merged(
        VertexIn in [[stage_in]],
        uint instanceID [[instance_id]],
        ushort eye [[amplification_id]],
        constant PBRViewUniforms &view [[buffer(1)]],
        constant PBRInstance *instances [[buffer(2)]],
        constant uint *instanceRecords [[buffer(8)]]
    ) {
        Fragment out = instancedFragment(in, in.position, in.normal, in.tangent, instances[instanceID], view, eye);
        out.record = instanceRecords[instanceID];
        return out;
    }

    [[vertex]] Fragment vertex_main_morphed(
        VertexIn in [[stage_in]],
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        ushort eye [[amplification_id]],
        constant PBRViewUniforms &view [[buffer(1)]],
        constant PBRInstance *instances [[buffer(2)]],
        constant PBRMorphUniforms &morph [[buffer(5)]],
        constant PBRMorphDelta *morphDeltas [[buffer(6)]],
        constant float *morphWeights [[buffer(7)]]
    ) {
        float3 position = in.position;
        float3 normal = in.normal;
        float4 tangent = in.tangent;
        applyMorph(position, normal, tangent, vertexID, morph, morphDeltas, morphWeights);
        return instancedFragment(in, position, normal, tangent, instances[instanceID], view, eye);
    }

    // Skinned vertices are placed by their joints; the mesh node's transform is ignored, per the glTF spec.
    [[vertex]] Fragment vertex_skinned(
        SkinnedVertexIn in [[stage_in]],
        ushort eye [[amplification_id]],
        constant PBRViewUniforms &view [[buffer(1)]],
        constant float4x4 *jointMatrices [[buffer(3)]]
    ) {
        return skinnedFragment(in, in.position, in.normal, in.tangent, jointMatrices, view, eye);
    }

    // Merged skinned geometry: every skin's joint matrices in one palette; each record starts at its own offset.
    [[vertex]] Fragment vertex_skinned_merged(
        SkinnedVertexIn in [[stage_in]],
        uint instanceID [[instance_id]],
        ushort eye [[amplification_id]],
        constant PBRViewUniforms &view [[buffer(1)]],
        constant float4x4 *jointMatrices [[buffer(3)]],
        constant uint *instanceRecords [[buffer(8)]],
        constant uint *recordJointOffsets [[buffer(9)]]
    ) {
        const uint record = instanceRecords[instanceID];
        Fragment out = skinnedFragment(in, in.position, in.normal, in.tangent, jointMatrices + recordJointOffsets[record], view, eye);
        out.record = record;
        return out;
    }

    [[vertex]] Fragment vertex_skinned_morphed(
        SkinnedVertexIn in [[stage_in]],
        uint vertexID [[vertex_id]],
        ushort eye [[amplification_id]],
        constant PBRViewUniforms &view [[buffer(1)]],
        constant float4x4 *jointMatrices [[buffer(3)]],
        constant PBRMorphUniforms &morph [[buffer(5)]],
        constant PBRMorphDelta *morphDeltas [[buffer(6)]],
        constant float *morphWeights [[buffer(7)]]
    ) {
        // Morph targets apply before skinning, per the glTF spec.
        float3 position = in.position;
        float3 normal = in.normal;
        float4 tangent = in.tangent;
        applyMorph(position, normal, tangent, vertexID, morph, morphDeltas, morphWeights);
        return skinnedFragment(in, position, normal, tangent, jointMatrices, view, eye);
    }

    Fragment skinnedFragment(SkinnedVertexIn in, float3 position, float3 normal, float4 tangent, constant float4x4 *jointMatrices, constant PBRViewUniforms &view, ushort eye) {
        const float4x4 skin =
            in.weights.x * jointMatrices[uint(in.joints.x)] +
            in.weights.y * jointMatrices[uint(in.joints.y)] +
            in.weights.z * jointMatrices[uint(in.joints.z)] +
            in.weights.w * jointMatrices[uint(in.joints.w)];
        // Normals need the inverse transpose, which matters when joints scale non-uniformly. The cofactor matrix is
        // that times the determinant, and normals are renormalized later, so only the determinant's sign is kept.
        const float3x3 linear = upperLeft(skin);
        const float3x3 cofactor = float3x3(cross(linear[1], linear[2]), cross(linear[2], linear[0]), cross(linear[0], linear[1]));
        const float3x3 normalMatrix = cofactor * (determinant(linear) < 0.0 ? -1.0 : 1.0);
        return makeFragment(position, normal, tangent, in.texCoord0, in.texCoord1, in.color, view, eye, view.modelMatrix * skin, normalMatrix);
    }

    void applyMorph(thread float3 &position, thread float3 &normal, thread float4 &tangent, uint vertexID, constant PBRMorphUniforms &morph, constant PBRMorphDelta *deltas, constant float *weights) {
        for (uint target = 0; target < morph.targetCount; ++target) {
            const PBRMorphDelta delta = deltas[target * morph.vertexCount + vertexID];
            position += weights[target] * delta.position;
            normal += weights[target] * delta.normal;
            tangent.xyz += weights[target] * delta.tangent;
        }
    }

    Fragment makeFragment(float3 position, float3 normal, float4 tangent, float2 texCoord0, float2 texCoord1, float4 color, constant PBRViewUniforms &view, ushort eye, float4x4 modelMatrix, float3x3 normalMatrix) {
        Fragment out;
        const float4 world = modelMatrix * float4(position, 1.0);
        out.position = view.viewProjectionMatrices[eye] * world;
        out.eye = eye;
        out.worldPosition = world.xyz / world.w;
        out.normal = upperLeft(view.modelNormalMatrix) * (normalMatrix * normal);
        out.tangent = float4(upperLeft(modelMatrix) * tangent.xyz, tangent.w);
        out.texCoord0 = texCoord0;
        out.texCoord1 = texCoord1;
        out.color = color;
        out.modelScale = (length(modelMatrix[0].xyz) + length(modelMatrix[1].xyz) + length(modelMatrix[2].xyz)) / 3.0;
        out.pointSize = 1.0;
        out.record = 0;
        return out;
    }

    float2 slotUV(PBRTextureSlot slot, float2 texCoord0, float2 texCoord1) {
        const float2 uv = slot.texCoord == 1 ? texCoord1 : texCoord0;
        return (slot.transform * float3(uv, 1.0)).xy;
    }

    float3 fresnelSchlick(float3 f0, float VdotH) {
        return f0 + (1.0 - f0) * pow(clamp(1.0 - VdotH, 0.0, 1.0), 5.0);
    }

    // KHR_materials_iridescence thin-film interference (Belcour & Barla 2017), ported from three.js.

    float3 fresnel0ToIor(float3 fresnel0) {
        const float3 root = sqrt(fresnel0);
        return (1.0 + root) / (1.0 - root);
    }

    float3 iorToFresnel0(float3 transmittedIor, float incidentIor) {
        const float3 ratio = (transmittedIor - incidentIor) / (transmittedIor + incidentIor);
        return ratio * ratio;
    }

    // Spectral sensitivity of the eye to an optical path difference (nanometers), in linear Rec. 709.
    float3 evaluateSensitivity(float pathDifference, float3 shift) {
        const float phase = 2.0 * kPi * pathDifference * 1.0e-9;
        const float3 value = float3(5.4856e-13, 4.4201e-13, 5.2481e-13);
        const float3 position = float3(1.6810e+06, 1.7953e+06, 2.2084e+06);
        const float3 variance = float3(4.3278e+09, 9.3046e+09, 6.6121e+09);
        float3 xyz = value * sqrt(2.0 * kPi * variance) * cos(position * phase + shift) * exp(-phase * phase * variance);
        xyz.x += 9.7470e-14 * sqrt(2.0 * kPi * 4.5282e+09) * cos(2.2399e+06 * phase + shift.x) * exp(-4.5282e+09 * phase * phase);
        xyz /= 1.0685e-7;
        const float3x3 xyzToRec709 = float3x3(
            float3(3.2404542, -0.9692660, 0.0556434),
            float3(-1.5371385, 1.8760108, -0.2040259),
            float3(-0.4985314, 0.0415560, 1.0572252)
        );
        return xyzToRec709 * xyz;
    }

    // Fresnel reflectance of a film of `filmIor` and `thickness` nanometres over a base with reflectance `baseF0`.
    float3 evaluateIridescence(float outsideIor, float filmIor, float cosTheta1, float thickness, float3 baseF0) {
        // A vanishing film fades to the base surface.
        const float iridescenceIor = mix(outsideIor, filmIor, smoothstep(0.0, 0.03, thickness));
        const float sinTheta2Squared = (outsideIor / iridescenceIor) * (outsideIor / iridescenceIor) * (1.0 - cosTheta1 * cosTheta1);
        const float cosTheta2Squared = 1.0 - sinTheta2Squared;
        if (cosTheta2Squared < 0.0) {
            return float3(1.0); // Total internal reflection.
        }
        const float cosTheta2 = sqrt(cosTheta2Squared);

        // First interface: outside to film.
        const float r0 = iorToFresnel0(float3(iridescenceIor), outsideIor).x;
        const float r12 = fresnelSchlick(float3(r0), cosTheta1).x;
        const float t121 = 1.0 - r12;
        const float phi12 = iridescenceIor < outsideIor ? kPi : 0.0;
        const float phi21 = kPi - phi12;

        // Second interface: film to base.
        const float3 baseIor = fresnel0ToIor(clamp(baseF0, 0.0, 0.9999));
        const float3 r1 = iorToFresnel0(baseIor, iridescenceIor);
        const float3 r23 = fresnelSchlick(r1, cosTheta2);
        const float3 phi23 = select(float3(0.0), float3(kPi), baseIor < iridescenceIor);

        const float pathDifference = 2.0 * iridescenceIor * thickness * cosTheta2;
        const float3 phi = phi21 + phi23;
        const float3 r123 = clamp(r12 * r23, 1e-5, 0.9999);
        const float3 rootR123 = sqrt(r123);
        const float3 rs = t121 * t121 * r23 / (1.0 - r123);
        float3 result = r12 + rs;
        float3 cm = rs - t121;
        for (int m = 1; m <= 2; ++m) {
            cm *= rootR123;
            result += cm * 2.0 * evaluateSensitivity(float(m) * pathDifference, float(m) * phi);
        }
        return max(result, float3(0.0));
    }

    // KHR_materials_anisotropy GGX terms (as in three.js). alphaT runs along the anisotropy direction, alphaB across it.

    float distributionGGXAnisotropic(float alphaT, float alphaB, float NdotH, float TdotH, float BdotH) {
        const float a2 = alphaT * alphaB;
        const float3 v = float3(alphaB * TdotH, alphaT * BdotH, a2 * NdotH);
        const float w2 = a2 / dot(v, v);
        return a2 * w2 * w2 / kPi;
    }

    float visibilitySmithGGXCorrelatedAnisotropic(float alphaT, float alphaB, float TdotV, float BdotV, float TdotL, float BdotL, float NdotV, float NdotL) {
        const float gv = NdotL * length(float3(alphaT * TdotV, alphaB * BdotV, NdotV));
        const float gl = NdotV * length(float3(alphaT * TdotL, alphaB * BdotL, NdotL));
        return saturate(0.5 / (gv + gl));
    }

    // KHR_materials_sheen terms (as in three.js): Charlie distribution, Neubelt visibility, and a fitted IBL term.

    float distributionCharlie(float roughness, float NdotH) {
        const float inverseAlpha = 1.0 / (roughness * roughness);
        const float sin2h = max(1.0 - NdotH * NdotH, 0.0078125);
        return (2.0 + inverseAlpha) * pow(sin2h, inverseAlpha * 0.5) / (2.0 * kPi);
    }

    float visibilityNeubelt(float NdotV, float NdotL) {
        return saturate(1.0 / (4.0 * (NdotL + NdotV - NdotL * NdotV)));
    }

    float environmentSheenBRDF(float NdotV, float roughness) {
        const float r2 = roughness * roughness;
        const float a = roughness < 0.25 ? -339.2 * r2 + 161.4 * roughness - 25.9 : -8.48 * r2 + 14.3 * roughness - 9.95;
        const float b = roughness < 0.25 ? 44.0 * r2 - 23.7 * roughness + 3.26 : 1.97 * r2 - 3.27 * roughness + 0.72;
        const float dg = exp(a * NdotV + b) + (roughness < 0.25 ? 0.0 : 0.1 * (roughness - 0.25));
        return saturate(dg / kPi);
    }

    // Inverse of Schlick's approximation: the F0 that gives `fresnel` at this angle.
    float3 schlickToF0(float3 fresnel, float cosTheta) {
        const float x = clamp(1.0 - cosTheta, 0.0, 1.0);
        const float x5 = clamp(x * x * x * x * x, 0.0, 0.9999);
        return (fresnel - x5) / (1.0 - x5);
    }


    // KHR_lights_punctual range attenuation.
    float rangeAttenuation(float range, float distance) {
        const float inverseSquare = 1.0 / max(distance * distance, 1e-4);
        if (range <= 0.0) {
            return inverseSquare;
        }
        return clamp(1.0 - pow(distance / range, 4.0), 0.0, 1.0) * inverseSquare;
    }

    // PCF in one slice; 1 is lit. Positions outside the slice's view are lit.
    float sliceShadow(float3 world, float4x4 viewProjection, float mapSize, int radius, depth2d_array<float> shadowMap, sampler shadowSampler, uint slice) {
        const float4 clip = viewProjection * float4(world, 1);
        const float3 ndc = clip.xyz / clip.w;
        const float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        if (any(uv < 0.0) || any(uv > 1.0) || ndc.z < 0.0 || ndc.z > 1.0) {
            return 1.0;
        }
        float lit = 0.0;
        const float texel = 1.0 / mapSize;
        for (int x = -radius; x <= radius; x++) {
            for (int y = -radius; y <= radius; y++) {
                lit += shadowMap.sample_compare(shadowSampler, uv + float2(x, y) * texel, slice, ndc.z, level(0));
            }
        }
        const float side = float(2 * radius + 1);
        return lit / (side * side);
    }

    // How much of `light` reaches `world`: the product of its slices' PCF results.
    float lightShadow(PBRLight light, float3 world, constant PBRShadowUniforms &shadow, depth2d_array<float> shadowMap, sampler shadowSampler) {
        if (shadow.enabled == 0 || light.shadowSliceCount <= 0) {
            return 1.0;
        }
        float lit = 1.0;
        const int end = min(light.shadowSliceStart + light.shadowSliceCount, kPBRMaxShadowSliceCount);
        for (int slice = max(light.shadowSliceStart, 0); slice < end; slice++) {
            lit *= sliceShadow(world, shadow.sliceViewProjections[slice], shadow.mapSize, shadow.radius, shadowMap, shadowSampler, uint(slice));
        }
        return lit;
    }

    float4 shade(
        Fragment in,
        bool frontFacing,
        constant PBRMaterialUniforms &material,
        constant PBRFrameUniforms &frame,
        constant PBRLight *lights,
        constant PBRMaterialResources &materialResources,
        texturecube<float> environmentIrradiance,
        texturecube<float> environmentSpecular,
        texture2d<float> brdfLookup,
        texture2d_array<float> transmissionScene,
        sampler environmentSampler,
        constant PBRShadowUniforms &shadow,
        depth2d_array<float> shadowMap,
        sampler shadowSampler
    );

    // Data (normals, factors, UVs) is shown as its value on screen: the sRGB target encodes linear output, so decode
    // first. Colors (base color, emissive, F0, sheen) are already linear and go out as they are.
    float3 debugData(float3 value) {
        return pow(saturate(value), 2.2);
    }

    float3 debugDirection(float3 direction) {
        return debugData(direction * 0.5 + 0.5);
    }

    float3 debugColor(
        PBRShaderDebugView view,
        Fragment in,
        bool frontFacing,
        constant PBRMaterialUniforms &material,
        constant PBRMaterialResources &materialResources,
        float4 baseColor,
        float metallic,
        float perceptualRoughness,
        float3 normal,
        float3 geometricNormal,
        float3 tangent,
        float3 bitangent,
        float3 f0,
        float transmission,
        float diffuseTransmission,
        float clearcoat,
        float3 sheenColor,
        float iridescence
    ) {
        switch (view) {
        case kPBRDebugViewBaseColor: return baseColor.rgb;
        case kPBRDebugViewAlpha: return debugData(float3(baseColor.a));
        case kPBRDebugViewMetallic: return debugData(float3(metallic));
        case kPBRDebugViewRoughness: return debugData(float3(perceptualRoughness));
        case kPBRDebugViewOcclusion: {
            float occlusion = 1.0;
            if (material.occlusion.enabled) {
                const float sample = materialResources.textures[kPBRTextureOcclusion].sample(materialResources.samplers[kPBRTextureOcclusion], slotUV(material.occlusion, in.texCoord0, in.texCoord1)).r;
                occlusion = 1.0 + material.occlusionStrength * (sample - 1.0);
            }
            return debugData(float3(occlusion));
        }
        case kPBRDebugViewEmissive: {
            float3 emissive = material.emissiveFactor * material.emissiveStrength;
            if (material.emissive.enabled) {
                emissive *= materialResources.textures[kPBRTextureEmissive].sample(materialResources.samplers[kPBRTextureEmissive], slotUV(material.emissive, in.texCoord0, in.texCoord1)).rgb;
            }
            return emissive;
        }
        case kPBRDebugViewShadingNormal: return debugDirection(normal);
        case kPBRDebugViewGeometricNormal: return debugDirection(geometricNormal);
        case kPBRDebugViewTangent: return debugDirection(tangent);
        case kPBRDebugViewBitangent: return debugDirection(bitangent);
        case kPBRDebugViewTangentHandedness:
            return dot(cross(geometricNormal, tangent), bitangent) >= 0.0 ? float3(0, 1, 0) : float3(1, 0, 0);
        case kPBRDebugViewTexCoord0: return debugData(float3(fract(in.texCoord0), 0.0));
        case kPBRDebugViewTexCoord1: return debugData(float3(fract(in.texCoord1), 0.0));
        case kPBRDebugViewUVChecker: {
            const int2 cell = int2(floor(in.texCoord0 * 8.0));
            return ((cell.x + cell.y) & 1) == 0 ? float3(0.9) : float3(0.05);
        }
        case kPBRDebugViewFrontFacing: return frontFacing ? float3(0, 1, 0) : float3(1, 0, 0);
        case kPBRDebugViewSpecularF0: return f0;
        case kPBRDebugViewTransmission: return debugData(float3(transmission));
        case kPBRDebugViewDiffuseTransmission: return debugData(float3(diffuseTransmission));
        case kPBRDebugViewClearcoat: return debugData(float3(clearcoat));
        case kPBRDebugViewSheen: return sheenColor;
        case kPBRDebugViewIridescence: return debugData(float3(iridescence));
        default: return float3(1, 0, 1);
        }
    }

    // Draws the triangle's edges over `color`: about a pixel wide (from the barycentrics' screen-space rate of change)
    // and anti-aliased, in a light cyan that reads over both lit shading and the debug views.
    float4 withWireframe(float4 color, float3 barycentric, constant PBRFrameUniforms &frame, constant PBRMaterialUniforms &material) {
        if (!frame.showsWireframe || material.isPointOrLine) {
            return color;
        }
        const float3 width = fwidth(barycentric);
        const float3 inside = smoothstep(float3(0.0), width * 1.25, barycentric);
        const float edge = 1.0 - min(min(inside.x, inside.y), inside.z);
        const float3 wire = float3(0.2, 0.85, 1.0);
        return float4(mix(color.rgb, wire, edge), max(color.a, edge));
    }

    [[fragment]] float4 fragment_main(
        Fragment in [[stage_in]],
        bool frontFacing [[front_facing]],
        float3 barycentric [[barycentric_coord]],
        constant PBRMaterialUniforms &material [[buffer(0)]],
        constant PBRFrameUniforms &frame [[buffer(1)]],
        constant PBRLight *lights [[buffer(2)]],
        constant PBRMaterialResources &materialResources [[buffer(3)]],
        constant PBRShadowUniforms &shadow [[buffer(4)]],
        texturecube<float> environmentIrradiance [[texture(0)]],
        texturecube<float> environmentSpecular [[texture(1)]],
        texture2d<float> brdfLookup [[texture(2)]],
        texture2d_array<float> transmissionScene [[texture(3)]],
        depth2d_array<float> shadowMap [[texture(4)]],
        sampler environmentSampler [[sampler(0)]],
        sampler shadowSampler [[sampler(1)]]
    ) {
        return withWireframe(shade(in, frontFacing, material, frame, lights, materialResources, environmentIrradiance, environmentSpecular, brdfLookup, transmissionScene, environmentSampler, shadow, shadowMap, shadowSampler), barycentric, frame, material);
    }

    // Merged static geometry: each draw record has its own material, selected by the record index the vertex stage
    // passes along.
    [[fragment]] float4 fragment_merged(
        Fragment in [[stage_in]],
        bool frontFacing [[front_facing]],
        float3 barycentric [[barycentric_coord]],
        constant PBRMaterialUniforms *recordMaterials [[buffer(0)]],
        constant PBRFrameUniforms &frame [[buffer(1)]],
        constant PBRLight *lights [[buffer(2)]],
        constant PBRMaterialResources *recordResources [[buffer(3)]],
        constant PBRShadowUniforms &shadow [[buffer(4)]],
        texturecube<float> environmentIrradiance [[texture(0)]],
        texturecube<float> environmentSpecular [[texture(1)]],
        texture2d<float> brdfLookup [[texture(2)]],
        texture2d_array<float> transmissionScene [[texture(3)]],
        depth2d_array<float> shadowMap [[texture(4)]],
        sampler environmentSampler [[sampler(0)]],
        sampler shadowSampler [[sampler(1)]]
    ) {
        constant PBRMaterialUniforms &material = recordMaterials[in.record];
        return withWireframe(shade(in, frontFacing, material, frame, lights, recordResources[in.record], environmentIrradiance, environmentSpecular, brdfLookup, transmissionScene, environmentSampler, shadow, shadowMap, shadowSampler), barycentric, frame, material);
    }

    float4 shade(
        Fragment in,
        bool frontFacing,
        constant PBRMaterialUniforms &material,
        constant PBRFrameUniforms &frame,
        constant PBRLight *lights,
        constant PBRMaterialResources &materialResources,
        texturecube<float> environmentIrradiance,
        texturecube<float> environmentSpecular,
        texture2d<float> brdfLookup,
        texture2d_array<float> transmissionScene,
        sampler environmentSampler,
        constant PBRShadowUniforms &shadow,
        depth2d_array<float> shadowMap,
        sampler shadowSampler
    ) {
        // The material's textures come from one argument buffer, so a draw binds them all at once.
        const texture2d<float> baseColorTexture = materialResources.textures[kPBRTextureBaseColor];
        const texture2d<float> metallicRoughnessTexture = materialResources.textures[kPBRTextureMetallicRoughness];
        const texture2d<float> normalTexture = materialResources.textures[kPBRTextureNormal];
        const texture2d<float> occlusionTexture = materialResources.textures[kPBRTextureOcclusion];
        const texture2d<float> emissiveTexture = materialResources.textures[kPBRTextureEmissive];
        const texture2d<float> transmissionTexture = materialResources.textures[kPBRTextureTransmission];
        const texture2d<float> thicknessTexture = materialResources.textures[kPBRTextureThickness];
        const texture2d<float> specularTexture = materialResources.textures[kPBRTextureSpecular];
        const texture2d<float> specularColorTexture = materialResources.textures[kPBRTextureSpecularColor];
        const texture2d<float> iridescenceTexture = materialResources.textures[kPBRTextureIridescence];
        const texture2d<float> iridescenceThicknessTexture = materialResources.textures[kPBRTextureIridescenceThickness];
        const texture2d<float> anisotropyTexture = materialResources.textures[kPBRTextureAnisotropy];
        const texture2d<float> sheenColorTexture = materialResources.textures[kPBRTextureSheenColor];
        const texture2d<float> sheenRoughnessTexture = materialResources.textures[kPBRTextureSheenRoughness];
        const texture2d<float> clearcoatTexture = materialResources.textures[kPBRTextureClearcoat];
        const texture2d<float> clearcoatRoughnessTexture = materialResources.textures[kPBRTextureClearcoatRoughness];
        const texture2d<float> clearcoatNormalTexture = materialResources.textures[kPBRTextureClearcoatNormal];
        const texture2d<float> diffuseTransmissionTexture = materialResources.textures[kPBRTextureDiffuseTransmission];
        const texture2d<float> diffuseTransmissionColorTexture = materialResources.textures[kPBRTextureDiffuseTransmissionColor];
        const texture2d<float> retroreflectionTexture = materialResources.textures[kPBRTextureRetroreflection];
        const sampler baseColorSampler = materialResources.samplers[kPBRTextureBaseColor];
        const sampler metallicRoughnessSampler = materialResources.samplers[kPBRTextureMetallicRoughness];
        const sampler normalSampler = materialResources.samplers[kPBRTextureNormal];
        const sampler occlusionSampler = materialResources.samplers[kPBRTextureOcclusion];
        const sampler emissiveSampler = materialResources.samplers[kPBRTextureEmissive];
        const sampler transmissionSampler = materialResources.samplers[kPBRTextureTransmission];
        const sampler thicknessSampler = materialResources.samplers[kPBRTextureThickness];
        const sampler specularSampler = materialResources.samplers[kPBRTextureSpecular];
        const sampler specularColorSampler = materialResources.samplers[kPBRTextureSpecularColor];
        const sampler iridescenceSampler = materialResources.samplers[kPBRTextureIridescence];
        const sampler iridescenceThicknessSampler = materialResources.samplers[kPBRTextureIridescenceThickness];
        const sampler anisotropySampler = materialResources.samplers[kPBRTextureAnisotropy];
        const sampler sheenColorSampler = materialResources.samplers[kPBRTextureSheenColor];
        const sampler sheenRoughnessSampler = materialResources.samplers[kPBRTextureSheenRoughness];
        const sampler clearcoatSampler = materialResources.samplers[kPBRTextureClearcoat];
        const sampler clearcoatRoughnessSampler = materialResources.samplers[kPBRTextureClearcoatRoughness];
        const sampler clearcoatNormalSampler = materialResources.samplers[kPBRTextureClearcoatNormal];
        const sampler diffuseTransmissionSampler = materialResources.samplers[kPBRTextureDiffuseTransmission];
        const sampler diffuseTransmissionColorSampler = materialResources.samplers[kPBRTextureDiffuseTransmissionColor];
        const sampler retroreflectionSampler = materialResources.samplers[kPBRTextureRetroreflection];
        // Base color
        float4 baseColor = material.baseColorFactor * in.color;
        if (material.baseColor.enabled) {
            baseColor *= baseColorTexture.sample(baseColorSampler, slotUV(material.baseColor, in.texCoord0, in.texCoord1));
        }

        if (material.alphaMode == kPBRAlphaModeMask) {
            if (baseColor.a < material.alphaCutoff) {
                discard_fragment();
            }
            baseColor.a = 1.0;
        } else if (material.alphaMode == kPBRAlphaModeOpaque) {
            baseColor.a = 1.0;
        }

        if (material.unlit) {
            if (frame.debugView != kPBRDebugViewLit) {
                // Unlit materials have no lighting inputs: show their color for the color views, dark gray otherwise.
                const float3 value = frame.debugView == kPBRDebugViewBaseColor ? baseColor.rgb
                    : frame.debugView == kPBRDebugViewAlpha ? debugData(float3(baseColor.a)) : float3(0.01);
                return float4(value, 1.0);
            }
            // Unlit colors still go through exposure and tone mapping, as in three.js.
            return float4(frame.linearOutput ? baseColor.rgb : toneMap(baseColor.rgb * frame.exposure, frame.toneMapping), baseColor.a);
        }

        // Tangent frame. Without vertex tangents, derive one from screen-space derivatives.
        const float2 normalUV = slotUV(material.normal, in.texCoord0, in.texCoord1);
        float3 geometricNormal;
        if (material.hasNormals) {
            geometricNormal = normalize(in.normal);
        } else {
            // No NORMAL attribute: the triangle's flat normal, from how the world position changes across the pixel.
            // It is turned to face the viewer, then given the winding's sign, so the back-face flip below behaves as
            // it does for real normals.
            float3 faceNormal = normalize(cross(dfdx(in.worldPosition), dfdy(in.worldPosition)));
            if (dot(faceNormal, frame.cameraPositions[in.eye] - in.worldPosition) < 0.0) {
                faceNormal = -faceNormal;
            }
            geometricNormal = frontFacing ? faceNormal : -faceNormal;
        }
        float3 tangent;
        float3 bitangent;
        if (material.hasTangents) {
            tangent = normalize(in.tangent.xyz);
            bitangent = cross(geometricNormal, tangent) * in.tangent.w;
        } else {
            const float2 uvDX = dfdx(normalUV);
            const float2 uvDY = dfdy(normalUV);
            const float3 positionDX = dfdx(in.worldPosition);
            const float3 positionDY = dfdy(in.worldPosition);
            const float determinant = uvDX.x * uvDY.y - uvDY.x * uvDX.y;
            float3 t = (uvDY.y * positionDX - uvDX.y * positionDY) / (abs(determinant) > 1e-12 ? determinant : 1e-12);
            t = t - geometricNormal * dot(geometricNormal, t);
            tangent = length_squared(t) > 1e-12 ? normalize(t) : float3(1, 0, 0);
            bitangent = cross(geometricNormal, tangent);
        }
        if (!frontFacing) {
            geometricNormal = -geometricNormal;
            tangent = -tangent;
            bitangent = -bitangent;
        }

        float3 normal = geometricNormal;
        if (material.normal.enabled) {
            float3 tangentNormal = normalTexture.sample(normalSampler, normalUV).xyz * 2.0 - 1.0;
            tangentNormal.xy *= material.normalScale;
            normal = normalize(float3x3(tangent, bitangent, geometricNormal) * tangentNormal);
        }

        // Metallic / roughness
        float metallic = material.metallicFactor;
        float perceptualRoughness = material.roughnessFactor;
        if (material.metallicRoughness.enabled) {
            const float4 sample = metallicRoughnessTexture.sample(metallicRoughnessSampler, slotUV(material.metallicRoughness, in.texCoord0, in.texCoord1));
            perceptualRoughness *= sample.g;
            metallic *= sample.b;
        }
        if (material.specularGlossiness) {
            // KHR_materials_pbrSpecularGlossiness: glossiness is in the specular texture's alpha.
            float glossiness = material.glossinessFactor;
            if (material.specularColor.enabled) {
                glossiness *= specularColorTexture.sample(specularColorSampler, slotUV(material.specularColor, in.texCoord0, in.texCoord1)).a;
            }
            perceptualRoughness = 1.0 - glossiness;
        }
        metallic = clamp(metallic, 0.0, 1.0);
        // Specular antialiasing (as in three.js): surfaces whose normal changes quickly across a pixel get rougher, so
        // small, dense or distant geometry does not sparkle.
        const float3 normalChange = max(abs(dfdx(geometricNormal)), abs(dfdy(geometricNormal)));
        const float geometryRoughness = max3(normalChange.x, normalChange.y, normalChange.z);
        perceptualRoughness = min(max(perceptualRoughness, 0.0525) + geometryRoughness, 1.0);
        const float alpha = perceptualRoughness * perceptualRoughness;

        // KHR_materials_anisotropy: direction in the tangent plane, and how strongly highlights stretch along it.
        float2 anisotropyDirection = float2(cos(material.anisotropyRotation), sin(material.anisotropyRotation)) * material.anisotropyStrength;
        if (material.anisotropy.enabled) {
            const float3 polar = anisotropyTexture.sample(anisotropySampler, slotUV(material.anisotropy, in.texCoord0, in.texCoord1)).rgb;
            const float2 textureDirection = normalize(polar.rg * 2.0 - 1.0) * polar.b;
            const float2x2 rotation = float2x2(anisotropyDirection, float2(-anisotropyDirection.y, anisotropyDirection.x));
            anisotropyDirection = rotation * textureDirection;
        }
        float anisotropy = length(anisotropyDirection);
        if (anisotropy == 0.0) {
            anisotropyDirection = float2(1.0, 0.0);
        } else {
            anisotropyDirection /= anisotropy;
            anisotropy = saturate(anisotropy);
        }
        const float alphaT = mix(alpha, 1.0, anisotropy * anisotropy);
        const float3 anisotropyT = tangent * anisotropyDirection.x + bitangent * anisotropyDirection.y;
        const float3 anisotropyB = bitangent * anisotropyDirection.x - tangent * anisotropyDirection.y;

        // KHR_materials_volume_scatter: what scatters back out of the volume has the multiscatter color.
        const float3 scatterColor = material.volumeScatter ? material.multiscatterColorFactor : float3(1.0);
        const float3 diffuseColor = mix(baseColor.rgb * scatterColor, float3(0.0), metallic);
        // Dielectric reflectance at normal incidence from the index of refraction (0.04 for the default 1.5).
        const float ior = material.ior;
        const float dielectricF0 = ((ior - 1.0) / (ior + 1.0)) * ((ior - 1.0) / (ior + 1.0));
        // KHR_materials_specular: tint and strength of dielectric specular reflection (metals are unaffected).
        float3 specularColor = material.specularColorFactor;
        if (material.specularColor.enabled) {
            specularColor *= specularColorTexture.sample(specularColorSampler, slotUV(material.specularColor, in.texCoord0, in.texCoord1)).rgb;
        }
        float dielectricSpecularStrength = material.specularFactor;
        if (material.specular.enabled) {
            dielectricSpecularStrength *= specularTexture.sample(specularSampler, slotUV(material.specular, in.texCoord0, in.texCoord1)).a;
        }
        const float specularStrength = mix(dielectricSpecularStrength, 1.0, metallic);
        const float3 f0 = mix(min(float3(dielectricF0) * specularColor, float3(1.0)), baseColor.rgb, metallic);

        const float3 view = normalize(frame.cameraPositions[in.eye] - in.worldPosition);
        const float NdotV = clamp(abs(dot(normal, view)), 1e-4, 1.0);

        // KHR_materials_iridescence: the film's view-dependent Fresnel replaces the surface's, by `iridescence`.
        float iridescence = material.iridescenceFactor;
        if (iridescence > 0.0 && material.iridescence.enabled) {
            iridescence *= iridescenceTexture.sample(iridescenceSampler, slotUV(material.iridescence, in.texCoord0, in.texCoord1)).r;
        }
        float3 iridescenceFresnel = float3(0.0);
        float3 iridescenceF0 = f0;
        if (iridescence > 0.0) {
            float thickness = material.iridescenceThicknessMaximum;
            if (material.iridescenceThickness.enabled) {
                const float blend = iridescenceThicknessTexture.sample(iridescenceThicknessSampler, slotUV(material.iridescenceThickness, in.texCoord0, in.texCoord1)).g;
                thickness = mix(material.iridescenceThicknessMinimum, material.iridescenceThicknessMaximum, blend);
            }
            iridescenceFresnel = evaluateIridescence(1.0, material.iridescenceIor, NdotV, thickness, f0);
            iridescenceF0 = schlickToF0(iridescenceFresnel, NdotV);
        }
        // Image-based lighting uses the film's equivalent F0.
        const float3 environmentF0 = mix(f0, iridescenceF0, iridescence);

        // KHR_materials_transmission / KHR_materials_volume. Transmitted light comes from the environment along the
        // refracted ray (the scene behind the surface is not visible), tinted by Beer-Lambert absorption.
        float transmission = material.transmissionFactor;
        if (material.transmission.enabled) {
            transmission *= transmissionTexture.sample(transmissionSampler, slotUV(material.transmission, in.texCoord0, in.texCoord1)).r;
        }
        float3 transmittedRadiance = float3(0.0);
        // With transmissionAsCoverage: how much of what is behind shows through (filled in below), for the alpha.
        float3 transmittedTint = float3(0.0);
        // With transmissionAsCoverage and a transmission scene (stereo pre-pass): how much of the model is behind, from
        // the scene's alpha. There the glass shows the refracted model; elsewhere what is behind shows through.
        float sceneCoverage = 0.0;
        if (transmission > 0.0 && frame.transmissionAsCoverage) {
            float thickness = material.thicknessFactor;
            if (material.thickness.enabled) {
                thickness *= thicknessTexture.sample(thicknessSampler, slotUV(material.thickness, in.texCoord0, in.texCoord1)).g;
            }
            thickness *= in.modelScale;
            transmittedTint = baseColor.rgb;
            if (isfinite(material.attenuationDistance) && material.attenuationDistance > 0.0) {
                transmittedTint *= pow(material.attenuationColor, float3(thickness / material.attenuationDistance));
            }
        }
        if (transmission > 0.0 && (!frame.transmissionAsCoverage || frame.hasTransmissionScene)) {
            float thickness = material.thicknessFactor;
            if (material.thickness.enabled) {
                thickness *= thicknessTexture.sample(thicknessSampler, slotUV(material.thickness, in.texCoord0, in.texCoord1)).g;
            }
            thickness *= in.modelScale;
            // KHR_materials_dispersion: each color channel refracts with its own IOR (as in three.js).
            const float halfSpread = (ior - 1.0) * 0.025 * material.dispersion;
            const int channelCount = material.dispersion > 0.0 ? 3 : 1;
            for (int channel = 0; channel < channelCount; ++channel) {
                const float channelIor = channelCount == 1 ? ior : ior + halfSpread * float(channel - 1);
                const float3 refracted = refract(-view, normal, 1.0 / channelIor);
                // Rough transmission blurs less as the IOR approaches 1 (Khronos sample viewer).
                const float roughness = perceptualRoughness * clamp(channelIor * 2.0 - 2.0, 0.0, 1.0);
                float3 radiance;
                if (frame.hasTransmissionScene) {
                    // Sample the opaque scene where the refracted ray leaves the volume, projected to the screen.
                    const float3 exitPosition = in.worldPosition + normalize(refracted) * thickness;
                    const float4 clip = frame.viewProjectionMatrices[in.eye] * float4(exitPosition, 1.0);
                    const float2 uv = float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
                    const float lod = roughness * (frame.transmissionSceneMipCount - 1.0);
                    // One slice per view: each eye sees its own view of the scene behind the glass.
                    const float4 scene = transmissionScene.sample(environmentSampler, uv, in.eye, level(lod));
                    radiance = scene.rgb;
                    sceneCoverage = scene.a;
                } else {
                    radiance = environmentSpecular.sample(environmentSampler, environmentDirection(refracted, frame.environmentRotation), level(roughness * (frame.specularMipCount - 1.0))).rgb * frame.environmentIntensity;
                }
                if (channelCount == 1) {
                    transmittedRadiance = radiance;
                } else {
                    transmittedRadiance[channel] = radiance[channel];
                }
            }
            if (isfinite(material.attenuationDistance) && material.attenuationDistance > 0.0) {
                transmittedRadiance *= pow(material.attenuationColor, float3(thickness / material.attenuationDistance));
            }
            transmittedRadiance *= baseColor.rgb;
        }

        // KHR_materials_diffuse_transmission: part of the diffuse lobe passes through the surface, so light from
        // behind it shows on this side, tinted by diffuseTransmissionColor. With KHR_materials_volume the light is also
        // absorbed over the thickness (Khronos sample viewer).
        float diffuseTransmission = material.diffuseTransmissionFactor;
        float3 diffuseTransmissionColor = material.diffuseTransmissionColorFactor;
        if (diffuseTransmission > 0.0) {
            if (material.diffuseTransmission.enabled) {
                diffuseTransmission *= diffuseTransmissionTexture.sample(diffuseTransmissionSampler, slotUV(material.diffuseTransmission, in.texCoord0, in.texCoord1)).a;
            }
            if (material.diffuseTransmissionColor.enabled) {
                diffuseTransmissionColor *= diffuseTransmissionColorTexture.sample(diffuseTransmissionColorSampler, slotUV(material.diffuseTransmissionColor, in.texCoord0, in.texCoord1)).rgb;
            }
            if (isfinite(material.attenuationDistance) && material.attenuationDistance > 0.0) {
                float thickness = material.thicknessFactor;
                if (material.thickness.enabled) {
                    thickness *= thicknessTexture.sample(thicknessSampler, slotUV(material.thickness, in.texCoord0, in.texCoord1)).g;
                }
                diffuseTransmissionColor *= pow(material.attenuationColor, float3(thickness * in.modelScale / material.attenuationDistance));
            }
            if (material.volumeScatter) {
                // Scattered light leaves both sides: half stays on the lit side as diffuse reflection.
                diffuseTransmissionColor *= scatterColor;
                diffuseTransmission *= 0.5;
            }
            diffuseTransmission = saturate(diffuseTransmission);
        }
        // Like the diffuse color, the transmitted diffuse light is only for the dielectric part.
        const float3 diffuseTransmittedColor = diffuseTransmissionColor * (1.0 - metallic);

        // KHR_materials_sheen
        float3 sheenColor = material.sheenColorFactor;
        float sheenRoughness = material.sheenRoughnessFactor;
        const bool hasSheen = any(sheenColor > 0.0);
        if (hasSheen) {
            if (material.sheenColor.enabled) {
                sheenColor *= sheenColorTexture.sample(sheenColorSampler, slotUV(material.sheenColor, in.texCoord0, in.texCoord1)).rgb;
            }
            if (material.sheenRoughness.enabled) {
                sheenRoughness *= sheenRoughnessTexture.sample(sheenRoughnessSampler, slotUV(material.sheenRoughness, in.texCoord0, in.texCoord1)).a;
            }
            sheenRoughness = clamp(sheenRoughness, 0.07, 1.0);
        }
        float3 sheen = float3(0.0);

        // KHR_materials_clearcoat: a dielectric (F0 = 0.04) GGX layer with its own roughness and normal. Without a
        // clearcoat normal texture it uses the geometric normal, not the base normal map.
        float clearcoat = material.clearcoatFactor;
        float clearcoatRoughness = material.clearcoatRoughnessFactor;
        float3 clearcoatNormal = geometricNormal;
        if (clearcoat > 0.0) {
            if (material.clearcoat.enabled) {
                clearcoat *= clearcoatTexture.sample(clearcoatSampler, slotUV(material.clearcoat, in.texCoord0, in.texCoord1)).r;
            }
            if (material.clearcoatRoughness.enabled) {
                clearcoatRoughness *= clearcoatRoughnessTexture.sample(clearcoatRoughnessSampler, slotUV(material.clearcoatRoughness, in.texCoord0, in.texCoord1)).g;
            }
            if (material.clearcoatNormal.enabled) {
                float3 tangentNormal = clearcoatNormalTexture.sample(clearcoatNormalSampler, slotUV(material.clearcoatNormal, in.texCoord0, in.texCoord1)).xyz * 2.0 - 1.0;
                tangentNormal.xy *= material.clearcoatNormalScale;
                clearcoatNormal = normalize(float3x3(tangent, bitangent, geometricNormal) * tangentNormal);
            }
            clearcoat = saturate(clearcoat);
            clearcoatRoughness = min(max(clearcoatRoughness, 0.0525) + geometryRoughness, 1.0);
        }
        const float clearcoatAlpha = clearcoatRoughness * clearcoatRoughness;
        const float clearcoatNdotV = clamp(abs(dot(clearcoatNormal, view)), 1e-4, 1.0);
        float3 clearcoatSpecular = float3(0.0);

        if (frame.debugView != kPBRDebugViewLit) {
            return float4(debugColor(frame.debugView, in, frontFacing, material, materialResources, baseColor, metallic, perceptualRoughness, normal, geometricNormal, tangent, bitangent, f0, transmission, diffuseTransmission, clearcoat, sheenColor, iridescence), 1.0);
        }

        // KHR_materials_retroreflection (Minimal Retroreflective Microfacet model): the metal and dielectric BRDFs are
        // blended, by this weight, with variants evaluated for the view reflected about the normal, which turns the
        // specular peak back toward the light. Clearcoat, sheen and transmission are not affected.
        float retroreflection = material.retroreflectionFactor;
        if (retroreflection > 0.0 && material.retroreflection.enabled) {
            retroreflection *= retroreflectionTexture.sample(retroreflectionSampler, slotUV(material.retroreflection, in.texCoord0, in.texCoord1)).r;
        }
        const float3 retroView = reflect(-view, normal);

        // Punctual lights
        float3 color = float3(0.0);
        for (int index = 0; index < frame.lightCount; ++index) {
            const PBRLight light = lights[index];
            float3 toLight;
            float attenuation = 1.0;
            if (light.type == kPBRLightTypeDirectional) {
                toLight = -normalize(light.direction);
            } else {
                const float3 delta = light.position - in.worldPosition;
                const float distance = length(delta);
                toLight = delta / max(distance, 1e-6);
                attenuation = rangeAttenuation(light.range, distance);
                if (light.type == kPBRLightTypeSpot) {
                    const float cd = dot(normalize(light.direction), -toLight);
                    attenuation *= smoothstep(light.outerConeCos, light.innerConeCos, cd);
                }
            }

            attenuation *= lightShadow(light, in.worldPosition, shadow, shadowMap, shadowSampler);
            const float3 radiance = light.color * light.intensity * attenuation;
            const float NdotL = clamp(dot(normal, toLight), 0.0, 1.0);
            if (NdotL <= 0.0) {
                // Light from behind reaches this side only by diffuse transmission. Its Fresnel term uses the light
                // mirrored to the front (Khronos sample viewer).
                const float backNdotL = saturate(-dot(normal, toLight));
                if (diffuseTransmission > 0.0 && backNdotL > 0.0) {
                    const float3 mirrored = normalize(toLight + 2.0 * normal * backNdotL);
                    const float mirroredVdotH = saturate(dot(view, normalize(mirrored + view)));
                    const float3 fresnel = mix(fresnelSchlick(f0, mirroredVdotH), iridescenceFresnel, iridescence) * specularStrength;
                    color += (1.0 - fresnel) * diffuseTransmittedColor / kPi * diffuseTransmission * (1.0 - transmission) * radiance * backNdotL;
                }
                continue;
            }
            const float3 halfVector = normalize(toLight + view);
            const float NdotH = clamp(dot(normal, halfVector), 0.0, 1.0);
            const float VdotH = clamp(dot(view, halfVector), 0.0, 1.0);

            const float3 fresnel = mix(fresnelSchlick(f0, VdotH), iridescenceFresnel, iridescence) * specularStrength;
            // Transmitted light (specular, then diffuse) replaces part of the diffuse lobe.
            const float3 diffuse = (1.0 - fresnel) * diffuseColor / kPi * (1.0 - diffuseTransmission) * (1.0 - transmission);
            float specularTerm;
            if (anisotropy > 0.0) {
                specularTerm = distributionGGXAnisotropic(alphaT, alpha, NdotH, dot(anisotropyT, halfVector), dot(anisotropyB, halfVector))
                    * visibilitySmithGGXCorrelatedAnisotropic(alphaT, alpha, dot(anisotropyT, view), dot(anisotropyB, view), dot(anisotropyT, toLight), dot(anisotropyB, toLight), NdotV, NdotL);
            } else {
                specularTerm = distributionGGX(NdotH, alpha) * visibilitySmithGGXCorrelated(NdotL, NdotV, alpha);
            }
            const float3 specular = fresnel * specularTerm;
            float3 lightBRDF = diffuse + specular;
            if (retroreflection > 0.0) {
                // The same BRDF with the reflected view: its half vector and Fresnel come from retroView. NdotV is the
                // same, since retroView is mirrored about the normal.
                const float3 retroHalf = normalize(toLight + retroView);
                const float retroNdotH = clamp(dot(normal, retroHalf), 0.0, 1.0);
                const float retroVdotH = clamp(dot(retroView, retroHalf), 0.0, 1.0);
                const float3 retroFresnel = mix(fresnelSchlick(f0, retroVdotH), iridescenceFresnel, iridescence) * specularStrength;
                const float3 retroDiffuse = (1.0 - retroFresnel) * diffuseColor / kPi * (1.0 - diffuseTransmission) * (1.0 - transmission);
                float retroSpecularTerm;
                if (anisotropy > 0.0) {
                    retroSpecularTerm = distributionGGXAnisotropic(alphaT, alpha, retroNdotH, dot(anisotropyT, retroHalf), dot(anisotropyB, retroHalf))
                        * visibilitySmithGGXCorrelatedAnisotropic(alphaT, alpha, dot(anisotropyT, retroView), dot(anisotropyB, retroView), dot(anisotropyT, toLight), dot(anisotropyB, toLight), NdotV, NdotL);
                } else {
                    retroSpecularTerm = distributionGGX(retroNdotH, alpha) * visibilitySmithGGXCorrelated(NdotL, NdotV, alpha);
                }
                lightBRDF = mix(lightBRDF, retroDiffuse + retroFresnel * retroSpecularTerm, retroreflection);
            }
            color += lightBRDF * radiance * NdotL;
            if (hasSheen) {
                sheen += sheenColor * distributionCharlie(sheenRoughness, NdotH) * visibilityNeubelt(NdotV, NdotL) * radiance * NdotL;
            }
            if (clearcoat > 0.0) {
                const float clearcoatNdotL = saturate(dot(clearcoatNormal, toLight));
                const float clearcoatNdotH = saturate(dot(clearcoatNormal, halfVector));
                const float3 clearcoatFresnel = fresnelSchlick(float3(0.04), VdotH);
                clearcoatSpecular += clearcoatFresnel * distributionGGX(clearcoatNdotH, clearcoatAlpha)
                    * visibilitySmithGGXCorrelated(clearcoatNdotL, clearcoatNdotV, clearcoatAlpha) * radiance * clearcoatNdotL;
            }
        }

        // Split-sum image-based lighting: prefiltered radiance times the BRDF integral from the lookup table.
        const float3 irradiance = environmentIrradiance.sample(environmentSampler, environmentDirection(normal, frame.environmentRotation)).rgb;
        // Anisotropic reflections sample along a normal bent toward the anisotropy direction.
        float3 reflectionNormal = normal;
        if (anisotropy > 0.0) {
            const float3 bent = normalize(cross(cross(anisotropyB, view), anisotropyB));
            const float straighten = 1.0 - anisotropy * (1.0 - perceptualRoughness);
            reflectionNormal = normalize(mix(bent, normal, straighten * straighten * straighten * straighten));
        }
        const float3 reflection = reflect(-view, reflectionNormal);
        const float lod = perceptualRoughness * (frame.specularMipCount - 1.0);
        float3 prefiltered = environmentSpecular.sample(environmentSampler, environmentDirection(reflection, frame.environmentRotation), level(lod)).rgb;
        if (retroreflection > 0.0) {
            // The reflected view's mirror direction points back along the view: retroreflection returns light from
            // behind the viewer. The split-sum terms depend only on NdotV, which is unchanged.
            const float3 retroReflection = reflect(-retroView, reflectionNormal);
            const float3 retroPrefiltered = environmentSpecular.sample(environmentSampler, environmentDirection(retroReflection, frame.environmentRotation), level(lod)).rgb;
            prefiltered = mix(prefiltered, retroPrefiltered, retroreflection);
        }
        const float2 brdf = brdfLookup.sample(environmentSampler, float2(NdotV, perceptualRoughness)).rg;
        // Multiple-scattering energy compensation (Fdez-Agüera 2019, as in three.js and the Khronos sample viewer).
        // Single-scattering GGX loses energy at high roughness; the lost share returns as diffuse-like reflection.
        const float3 fresnelRoughness = max(float3(1.0 - perceptualRoughness), environmentF0) - environmentF0;
        const float3 singleScatterFresnel = environmentF0 + fresnelRoughness * pow(1.0 - NdotV, 5.0);
        const float3 specularWeight = (singleScatterFresnel * brdf.x + brdf.y) * specularStrength;
        const float singleScatterEnergy = brdf.x + brdf.y;
        const float multiScatterEnergy = 1.0 - singleScatterEnergy;
        const float3 averageFresnel = environmentF0 + (1.0 - environmentF0) / 21.0;
        const float3 multiScatterWeight = multiScatterEnergy * specularWeight * averageFresnel / (1.0 - averageFresnel * multiScatterEnergy);
        // Light reflected by the specular lobes is not available to the diffuse lobe. Diffuse transmission swaps part of
        // it for light arriving from behind the surface.
        float3 diffuseIrradiance = irradiance * diffuseColor;
        if (diffuseTransmission > 0.0) {
            const float3 backIrradiance = environmentIrradiance.sample(environmentSampler, environmentDirection(-normal, frame.environmentRotation)).rgb;
            diffuseIrradiance = mix(diffuseIrradiance, backIrradiance * diffuseTransmittedColor, diffuseTransmission);
        }
        const float3 diffuseWeight = 1.0 - specularWeight - multiScatterWeight;
        // transmittedRadiance is already absolute radiance (scene or environment), so it is not scaled again.
        const float3 ambientDiffuse = mix(diffuseIrradiance * diffuseWeight * frame.environmentIntensity, transmittedRadiance * (1.0 - specularWeight), transmission);
        float3 ambient = ambientDiffuse + (prefiltered * specularWeight + irradiance * multiScatterWeight) * frame.environmentIntensity;
        // The irradiance map holds irradiance / pi; three.js's sheen term expects irradiance.
        float3 ambientSheen = hasSheen ? irradiance * kPi * sheenColor * environmentSheenBRDF(NdotV, sheenRoughness) * frame.environmentIntensity : float3(0.0);
        float3 ambientClearcoat = float3(0.0);
        if (clearcoat > 0.0) {
            const float3 clearcoatReflection = reflect(-view, clearcoatNormal);
            const float3 clearcoatRadiance = environmentSpecular.sample(environmentSampler, environmentDirection(clearcoatReflection, frame.environmentRotation), level(clearcoatRoughness * (frame.specularMipCount - 1.0))).rgb;
            const float2 clearcoatBRDF = brdfLookup.sample(environmentSampler, float2(clearcoatNdotV, clearcoatRoughness)).rg;
            ambientClearcoat = clearcoatRadiance * (0.04 * clearcoatBRDF.x + clearcoatBRDF.y) * frame.environmentIntensity;
        }
        if (material.occlusion.enabled) {
            const float occlusion = occlusionTexture.sample(occlusionSampler, slotUV(material.occlusion, in.texCoord0, in.texCoord1)).r;
            const float occlusionFactor = 1.0 + material.occlusionStrength * (occlusion - 1.0);
            ambient *= occlusionFactor;
            ambientSheen *= occlusionFactor;
            ambientClearcoat *= occlusionFactor;
        }
        color += ambient;

        // Emissive
        float3 emissive = material.emissiveFactor * material.emissiveStrength;
        if (material.emissive.enabled) {
            emissive *= emissiveTexture.sample(emissiveSampler, slotUV(material.emissive, in.texCoord0, in.texCoord1)).rgb;
        }
        color += emissive;

        // Sheen sits on top and takes energy from the layers below (three.js's albedo-scaling approximation).
        if (hasSheen) {
            color = color * (1.0 - 0.157 * max3(sheenColor.r, sheenColor.g, sheenColor.b)) + sheen + ambientSheen;
        }
        // The clearcoat reflects some light before it reaches the layers below.
        if (clearcoat > 0.0) {
            const float3 clearcoatFresnel = fresnelSchlick(float3(0.04), clearcoatNdotV);
            color = color * (1.0 - clearcoat * clearcoatFresnel) + (clearcoatSpecular + ambientClearcoat) * clearcoat;
        }

        if (!frame.linearOutput) {
            color = toneMap(color * frame.exposure, frame.toneMapping);
        }
        if (frame.transmissionAsCoverage && transmission > 0.0) {
            // Premultiplied: the surface's own light, plus what is behind scaled by 1 - alpha (the blend state). The
            // tint is reduced to its average, since blending scales what is behind by one value.
            const float3 throughput = transmission * transmittedTint * (1.0 - specularWeight);
            return float4(color, 1.0 - clamp((throughput.r + throughput.g + throughput.b) / 3.0, 0.0, 1.0) * (1.0 - sceneCoverage));
        }
        return float4(color, baseColor.a);
    }

} // namespace PBR
