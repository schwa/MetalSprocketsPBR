#pragma once

// Metal-only helpers shared by the PBR and IBL shaders. Not part of the Swift-visible umbrella header.

#ifdef __METAL_VERSION__
#include <metal_stdlib>

namespace PBRSupport {
    using namespace metal;

    constant float kPi = 3.14159265358979323846;

    inline float distributionGGX(float NdotH, float alpha) {
        const float alpha2 = alpha * alpha;
        const float f = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
        return alpha2 / (kPi * f * f);
    }

    // Height-correlated Smith visibility. Includes the 1 / (4 NdotL NdotV) term.
    inline float visibilitySmithGGXCorrelated(float NdotL, float NdotV, float alpha) {
        const float alpha2 = alpha * alpha;
        const float ggxV = NdotL * sqrt(NdotV * NdotV * (1.0 - alpha2) + alpha2);
        const float ggxL = NdotV * sqrt(NdotL * NdotL * (1.0 - alpha2) + alpha2);
        const float sum = ggxV + ggxL;
        return sum > 0.0 ? 0.5 / sum : 0.0;
    }

    // Khronos PBR Neutral tone mapper.
    inline float3 toneMapPBRNeutral(float3 color) {
        const float startCompression = 0.8 - 0.04;
        const float desaturation = 0.15;
        const float x = min(color.r, min(color.g, color.b));
        const float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
        color -= offset;
        const float peak = max(color.r, max(color.g, color.b));
        if (peak < startCompression) {
            return color;
        }
        const float d = 1.0 - startCompression;
        const float newPeak = 1.0 - d * d / (peak + d - startCompression);
        color *= newPeak / peak;
        const float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
        return mix(color, newPeak * float3(1.0), g);
    }

    // The other operators follow three.js r186's tonemapping_pars_fragment (MIT), so comparisons with the three.js
    // reference match. Exposure is applied before these.
    inline float3 toneMapACESFilmic(float3 color) {
        const float3x3 inputMatrix = float3x3(float3(0.59719, 0.07600, 0.02840), float3(0.35458, 0.90834, 0.13383), float3(0.04823, 0.01566, 0.83777));
        const float3x3 outputMatrix = float3x3(float3(1.60475, -0.10208, -0.00327), float3(-0.53108, 1.10813, -0.07276), float3(-0.07367, -0.00605, 1.07602));
        color = inputMatrix * (color / 0.6);
        const float3 a = color * (color + 0.0245786) - 0.000090537;
        const float3 b = color * (0.983729 * color + 0.4329510) + 0.238081;
        return saturate(outputMatrix * (a / b));
    }

    inline float3 toneMapAgX(float3 color) {
        const float3x3 sRGBToRec2020 = float3x3(float3(0.6274, 0.0691, 0.0164), float3(0.3293, 0.9195, 0.0880), float3(0.0433, 0.0113, 0.8956));
        const float3x3 rec2020ToSRGB = float3x3(float3(1.6605, -0.1246, -0.0182), float3(-0.5876, 1.1329, -0.1006), float3(-0.0728, -0.0083, 1.1187));
        const float3x3 inset = float3x3(float3(0.856627153315983, 0.137318972929847, 0.11189821299995), float3(0.0951212405381588, 0.761241990602591, 0.0767994186031903), float3(0.0482516061458583, 0.101439036467562, 0.811302368396859));
        const float3x3 outset = float3x3(float3(1.1271005818144368, -0.1413297634984383, -0.14132976349843826), float3(-0.11060664309660323, 1.157823702216272, -0.11060664309660294), float3(-0.016493938717834573, -0.016493938717834257, 1.2519364065950405));
        const float minEV = -12.47393;
        const float maxEV = 4.026069;
        color = inset * (sRGBToRec2020 * color);
        color = saturate((log2(max(color, 1e-10)) - minEV) / (maxEV - minEV));
        const float3 x2 = color * color;
        const float3 x4 = x2 * x2;
        color = 15.5 * x4 * x2 - 40.14 * x4 * color + 31.96 * x4 - 6.868 * x2 * color + 0.4298 * x2 + 0.1191 * color - 0.00232;
        color = pow(max(outset * color, 0.0), 2.2);
        return saturate(rec2020ToSRGB * color);
    }

    // A world direction in the environment's frame. An all-zero matrix (uniforms never set) leaves it unrotated.
    inline float3 environmentDirection(float3 direction, float3x3 rotation) {
        return all(rotation[0] == 0.0) ? direction : rotation * direction;
    }

    // `mode` is a PBRShaderToneMapping value; `color` already has exposure applied.
    inline float3 toneMap(float3 color, int mode) {
        switch (mode) {
        case 1: return saturate(color);                // Linear
        case 2: return toneMapACESFilmic(color);
        case 3: return toneMapAgX(color);
        case 4: return saturate(color / (1.0 + color)); // Reinhard
        case 5: return max(color, 0.0);                 // None: values above 1 survive in float targets
        default: return toneMapPBRNeutral(color);
        }
    }

    inline float2 hammersley(uint index, uint count) {
        return float2(float(index) / float(count), float(reverse_bits(index)) * 2.3283064365386963e-10);
    }

    inline float3x3 tangentFrame(float3 normal) {
        const float3 up = abs(normal.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
        const float3 tangent = normalize(cross(up, normal));
        return float3x3(tangent, cross(normal, tangent), normal);
    }

    inline float3 importanceSampleGGX(float2 xi, float3 normal, float alpha) {
        const float phi = 2.0 * kPi * xi.x;
        const float cosTheta = sqrt((1.0 - xi.y) / (1.0 + (alpha * alpha - 1.0) * xi.y));
        const float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
        return normalize(tangentFrame(normal) * float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta));
    }

    // Equirectangular mapping, row 0 at +Y. Same longitude convention as three.js (which stores row 0 at -Y).
    inline float2 equirectUV(float3 direction) {
        const float3 d = normalize(direction);
        return float2(atan2(d.z, d.x) / (2.0 * kPi) + 0.5, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / kPi);
    }

    inline float3 equirectDirection(float2 uv) {
        const float phi = (uv.x - 0.5) * 2.0 * kPi;
        const float theta = (0.5 - uv.y) * kPi;
        return float3(cos(theta) * cos(phi), sin(theta), cos(theta) * sin(phi));
    }

    // Direction through a cube texel; `uv` is 0...1 with v down, faces in Metal order +X -X +Y -Y +Z -Z.
    inline float3 cubeDirection(uint face, float2 uv) {
        const float2 p = uv * 2.0 - 1.0;
        switch (face) {
            case 0: return normalize(float3(1, -p.y, -p.x));
            case 1: return normalize(float3(-1, -p.y, p.x));
            case 2: return normalize(float3(p.x, 1, p.y));
            case 3: return normalize(float3(p.x, -1, -p.y));
            case 4: return normalize(float3(p.x, -p.y, 1));
            default: return normalize(float3(-p.x, -p.y, -1));
        }
    }
}
#endif
