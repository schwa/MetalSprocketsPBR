#include "MetalSprocketsPBRShaders.h"
#include "PBRShaderSupport.h"
#include "PBRLighting.h"

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
        constant LightingLight *lights [[buffer(2)]],
        constant PBRMaterialResources &materialResources [[buffer(3)]],
        constant LightingShadowUniforms &shadow [[buffer(4)]],
        constant LightingFrameResources &frameResources [[buffer(5)]]
    ) {
        return withWireframe(shade(in, frontFacing, material, frame, lights, materialResources, shadow, frameResources), barycentric, frame, material);
    }

    // Merged static geometry: each draw record has its own material, selected by the record index the vertex stage
    // passes along.
    [[fragment]] float4 fragment_merged(
        Fragment in [[stage_in]],
        bool frontFacing [[front_facing]],
        float3 barycentric [[barycentric_coord]],
        constant PBRMaterialUniforms *recordMaterials [[buffer(0)]],
        constant PBRFrameUniforms &frame [[buffer(1)]],
        constant LightingLight *lights [[buffer(2)]],
        constant PBRMaterialResources *recordResources [[buffer(3)]],
        constant LightingShadowUniforms &shadow [[buffer(4)]],
        constant LightingFrameResources &frameResources [[buffer(5)]]
    ) {
        constant PBRMaterialUniforms &material = recordMaterials[in.record];
        return withWireframe(shade(in, frontFacing, material, frame, lights, recordResources[in.record], shadow, frameResources), barycentric, frame, material);
    }

} // namespace PBR
