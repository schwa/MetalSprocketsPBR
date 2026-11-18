#include "MetalSprocketsPBRShaders.h"
#include "PBRShaderSupport.h"

// The environment drawn as the background. Prefiltering lives in MetalSprocketsLighting.

using namespace metal;
using namespace PBRSupport;

namespace PBRIBL {

    constexpr sampler sourceSampler(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);

    struct BackgroundFragment {
        float4 position [[position]];
        float2 ndc;
        uint eye [[flat]];
    };

    // One triangle covering the screen, per view. Drawn first without depth testing.
    [[vertex]] BackgroundFragment background_vertex(uint vertexID [[vertex_id]], ushort eye [[amplification_id]]) {
        const float2 p = float2((vertexID << 1) & 2, vertexID & 2) * 2.0 - 1.0;
        BackgroundFragment out;
        out.position = float4(p, 1.0, 1.0);
        out.ndc = p;
        out.eye = eye;
        return out;
    }

    [[fragment]] float4 background_fragment(
        BackgroundFragment in [[stage_in]],
        constant PBRBackgroundUniforms &uniforms [[buffer(0)]],
        texture2d<float> environment [[texture(0)]]
    ) {
        const float4 world = uniforms.inverseViewProjections[in.eye] * float4(in.ndc, 1.0, 1.0);
        const float3 direction = normalize(world.xyz / world.w);
        const float3 color = environment.sample(sourceSampler, equirectUV(environmentDirection(direction, uniforms.environmentRotation)), level(uniforms.lod)).rgb * uniforms.intensity;
        return float4(uniforms.linearOutput ? color : toneMap(color * uniforms.exposure, uniforms.toneMapping), 1.0);
    }

    // Copies a texture the size of the target (an upscaled frame) into it, pixel for pixel. Uses background_vertex.
    [[fragment]] float4 copy_fragment(BackgroundFragment in [[stage_in]], texture2d<float> source [[texture(0)]]) {
        return source.read(uint2(in.position.xy));
    }

} // namespace PBRIBL
