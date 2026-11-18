#pragma once

// Metal-only helpers shared by the PBR and IBL shaders. Not part of the Swift-visible umbrella header.

#ifdef __METAL_VERSION__
#include <metal_stdlib>
#include "MetalSprocketsLightingSupport.h"

namespace PBRSupport {
    using namespace metal;
    // GGX, sampling and environment-direction helpers.
    using namespace Lighting;

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
}
#endif
