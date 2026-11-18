#pragma once

// Metal-only helpers shared by the PBR and IBL shaders. Not part of the Swift-visible umbrella header.

#ifdef __METAL_VERSION__
#include <metal_stdlib>
#include "MetalSprocketsLightingSupport.h"
#include "MetalSprocketsLightingToneMapping.h"

namespace PBRSupport {
    using namespace metal;
    // GGX, sampling, environment-direction and tone mapping helpers.
    using namespace Lighting;
}
#endif
