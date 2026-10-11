#pragma once

#import "MetalSprocketsShaders.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface NSBundle (MetalSprocketsPBRShaders)
+ (NSBundle *)metalSprocketsPBRShadersBundle;
@end
NS_ASSUME_NONNULL_END
#endif

#ifdef __METAL_VERSION__
#import <metal_stdlib>
#endif

#import <simd/simd.h>

#import "PBRShaderTypes.h"
#import "PBRShaderSupport.h"
