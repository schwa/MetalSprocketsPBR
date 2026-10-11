#include "MetalSprocketsPBRShaders.h"
#include "PBRShaderSupport.h"

// Image-based lighting: environment sources, split-sum prefiltering, and the background.
// Sources are linear HDR equirectangular textures with a full mip chain.

using namespace metal;
using namespace PBRSupport;

namespace PBRIBL {

    constexpr sampler sourceSampler(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);

    // A rectangular light on the sphere, `center` must be normalized.
    float softbox(float3 direction, float3 center, float2 halfSize) {
        const float facing = dot(direction, center);
        if (facing <= 0.0) {
            return 0.0;
        }
        const float3 worldUp = abs(center.y) > 0.99 ? float3(0, 0, 1) : float3(0, 1, 0);
        const float3 right = normalize(cross(worldUp, center));
        const float3 up = cross(center, right);
        // Gnomonic projection onto the plane of the box.
        const float2 p = abs(float2(dot(direction, right), dot(direction, up)) / facing);
        const float2 inside = 1.0 - smoothstep(halfSize * 0.85, halfSize, p);
        return inside.x * inside.y;
    }

    // A neutral photo-studio: gray gradient walls with a few large softboxes.
    float3 studioRadiance(float3 d) {
        const float3 ceiling = float3(0.55, 0.56, 0.6);
        const float3 walls = float3(0.35);
        const float3 floor = float3(0.12, 0.115, 0.11);
        float3 color = d.y > 0.0 ? mix(walls, ceiling, smoothstep(0.0, 0.7, d.y)) : mix(walls, floor, smoothstep(0.0, 0.25, -d.y));
        color += 5.0 * softbox(d, float3(0, 1, 0), float2(0.6, 0.6));
        color += 8.0 * softbox(d, normalize(float3(-0.7, 0.35, 0.6)), float2(0.3, 0.45));
        color += 3.0 * softbox(d, normalize(float3(0.8, 0.25, 0.55)), float2(0.35, 0.35));
        color += 5.0 * softbox(d, normalize(float3(0.6, 0.3, -0.75)), float2(0.12, 0.5));
        return color;
    }

    [[kernel]] void equirect_studio(
        texture2d<float, access::write> output [[texture(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
            return;
        }
        const float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
        output.write(float4(studioRadiance(equirectDirection(uv)), 1.0), gid);
    }

    // A cube map of radiance (e.g. ARKit's environment probes) resampled to an equirectangular source, with a color
    // matrix (e.g. Display P3 to linear sRGB) and a brightness scale applied.
    [[kernel]] void equirect_from_cube(
        texturecube<float> cube [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant float3x3 &colorMatrix [[buffer(0)]],
        constant float &scale [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
            return;
        }
        const float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
        const float3 radiance = cube.sample(sourceSampler, equirectDirection(uv), level(0)).rgb;
        output.write(float4(max(colorMatrix * radiance * scale, 0.0), 1.0), gid);
    }

    [[kernel]] void equirect_uniform(
        texture2d<float, access::write> output [[texture(0)]],
        constant float4 &color [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
            return;
        }
        output.write(color, gid);
    }

    // Mip level of `source` whose texels cover roughly `sampleSolidAngle`.
    float sourceLevel(texture2d<float> source, float sampleSolidAngle) {
        const float texelSolidAngle = 4.0 * kPi / float(source.get_width() * source.get_height());
        return max(0.5 * log2(sampleSolidAngle / texelSolidAngle) + 1.0, 0.0);
    }

    // GGX prefiltering with N = V = R, using filtered importance sampling.
    [[kernel]] void prefilter_specular(
        texture2d<float> source [[texture(0)]],
        texturecube<float, access::write> output [[texture(1)]],
        constant PBRPrefilterParameters &parameters [[buffer(0)]],
        uint3 gid [[thread_position_in_grid]]
    ) {
        const uint size = output.get_width();
        if (gid.x >= size || gid.y >= size) {
            return;
        }
        const float3 normal = cubeDirection(gid.z, (float2(gid.xy) + 0.5) / float(size));
        if (parameters.roughness <= 0.0) {
            output.write(float4(source.sample(sourceSampler, equirectUV(normal), level(0)).rgb, 1.0), gid.xy, gid.z);
            return;
        }
        const float alpha = parameters.roughness * parameters.roughness;
        float3 sum = 0.0;
        float weight = 0.0;
        for (uint index = 0; index < parameters.sampleCount; ++index) {
            const float3 halfVector = importanceSampleGGX(hammersley(index, parameters.sampleCount), normal, alpha);
            const float3 toLight = normalize(2.0 * dot(normal, halfVector) * halfVector - normal);
            const float NdotL = dot(normal, toLight);
            if (NdotL <= 0.0) {
                continue;
            }
            // With V = N the GGX half-vector pdf reduces to D / 4.
            const float NdotH = saturate(dot(normal, halfVector));
            const float pdf = distributionGGX(NdotH, alpha) / 4.0;
            const float lod = sourceLevel(source, 1.0 / (float(parameters.sampleCount) * pdf + 1e-4));
            sum += source.sample(sourceSampler, equirectUV(toLight), level(lod)).rgb * NdotL;
            weight += NdotL;
        }
        output.write(float4(sum / max(weight, 1e-6), 1.0), gid.xy, gid.z);
    }

    // Cosine-weighted average radiance, i.e. irradiance / pi, so diffuse = irradiance * albedo.
    [[kernel]] void convolve_irradiance(
        texture2d<float> source [[texture(0)]],
        texturecube<float, access::write> output [[texture(1)]],
        constant PBRPrefilterParameters &parameters [[buffer(0)]],
        uint3 gid [[thread_position_in_grid]]
    ) {
        const uint size = output.get_width();
        if (gid.x >= size || gid.y >= size) {
            return;
        }
        const float3 normal = cubeDirection(gid.z, (float2(gid.xy) + 0.5) / float(size));
        const float3x3 frame = tangentFrame(normal);
        float3 sum = 0.0;
        for (uint index = 0; index < parameters.sampleCount; ++index) {
            const float2 xi = hammersley(index, parameters.sampleCount);
            const float phi = 2.0 * kPi * xi.x;
            const float cosTheta = sqrt(1.0 - xi.y);
            const float sinTheta = sqrt(xi.y);
            const float3 toLight = frame * float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            const float pdf = max(cosTheta, 1e-4) / kPi;
            const float lod = sourceLevel(source, 1.0 / (float(parameters.sampleCount) * pdf));
            sum += source.sample(sourceSampler, equirectUV(toLight), level(lod)).rgb;
        }
        output.write(float4(sum / float(parameters.sampleCount), 1.0), gid.xy, gid.z);
    }

    // Split-sum BRDF integral: x = scale applied to F0, y = bias. Indexed by (NdotV, perceptual roughness).
    [[kernel]] void brdf_lookup(
        texture2d<float, access::write> output [[texture(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
            return;
        }
        const float NdotV = (float(gid.x) + 0.5) / float(output.get_width());
        const float roughness = (float(gid.y) + 0.5) / float(output.get_height());
        const float alpha = roughness * roughness;
        const float3 view = float3(sqrt(1.0 - NdotV * NdotV), 0.0, NdotV);
        const float3 normal = float3(0, 0, 1);
        const uint sampleCount = 1024;
        float scale = 0.0;
        float bias = 0.0;
        for (uint index = 0; index < sampleCount; ++index) {
            const float3 halfVector = importanceSampleGGX(hammersley(index, sampleCount), normal, alpha);
            const float3 toLight = normalize(2.0 * dot(view, halfVector) * halfVector - view);
            const float NdotL = saturate(toLight.z);
            if (NdotL <= 0.0) {
                continue;
            }
            const float NdotH = saturate(halfVector.z);
            const float VdotH = saturate(dot(view, halfVector));
            const float visibility = visibilitySmithGGXCorrelated(NdotL, NdotV, alpha);
            const float weightedVisibility = visibility * 4.0 * NdotL * VdotH / max(NdotH, 1e-6);
            const float fresnel = pow(1.0 - VdotH, 5.0);
            scale += (1.0 - fresnel) * weightedVisibility;
            bias += fresnel * weightedVisibility;
        }
        output.write(float4(scale / float(sampleCount), bias / float(sampleCount), 0.0, 1.0), gid);
    }

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
