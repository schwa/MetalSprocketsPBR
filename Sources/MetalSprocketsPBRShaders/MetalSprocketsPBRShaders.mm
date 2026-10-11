#import <Foundation/Foundation.h>

@interface MetalSprocketsPBRShaders_BundleFinder : NSObject
@end

@implementation MetalSprocketsPBRShaders_BundleFinder
@end

@implementation NSBundle (MetalSprocketsPBRShaders)

+ (NSBundle *)metalSprocketsPBRShadersBundle {
    static NSBundle *moduleBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleName = @"MetalSprocketsPBR_MetalSprocketsPBRShaders";
        NSMutableArray<NSURL *> *candidates = [NSMutableArray array];

        // Under swift test, mainBundle is swiftpm-testing-helper, not the test bundle.
        BOOL isSPMTestMode = [[[NSProcessInfo processInfo] processName] isEqualToString:@"swiftpm-testing-helper"];

#if DEBUG
        // Overrides the bundle path for development.
        NSDictionary *env = [[NSProcessInfo processInfo] environment];
        NSString *overridePath = env[@"PACKAGE_RESOURCE_BUNDLE_PATH"] ?: env[@"PACKAGE_RESOURCE_BUNDLE_URL"];
        if (overridePath) {
            [candidates addObject:[NSURL fileURLWithPath:overridePath]];
        }
#endif

        // Standard SPM bundle locations for Xcode tests and apps.
        [candidates addObject:[NSBundle mainBundle].resourceURL];
        [candidates addObject:[[NSBundle bundleForClass:[MetalSprocketsPBRShaders_BundleFinder class]] resourceURL]];
        [candidates addObject:[NSBundle mainBundle].bundleURL];

        if (isSPMTestMode) {
            // swift test: .bundle files are siblings of the .xctest bundle in .build/debug.
            for (NSBundle *loadedBundle in [NSBundle allBundles]) {
                NSURL *bundleURL = loadedBundle.bundleURL;
                if (bundleURL && [[bundleURL pathExtension] isEqualToString:@"xctest"]) {
                    NSURL *parentDir = [bundleURL URLByDeletingLastPathComponent];
                    [candidates addObject:parentDir];
                }
            }
        }

        for (NSURL *candidate in candidates) {
            if (!candidate) continue;

            NSURL *bundlePath = [candidate URLByAppendingPathComponent:[bundleName stringByAppendingString:@".bundle"]];
            NSBundle *bundle = [NSBundle bundleWithURL:bundlePath];
            if (bundle) {
                moduleBundle = bundle;
                return;
            }
        }

        @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                       reason:[NSString stringWithFormat:@"Unable to find bundle named %@", bundleName]
                                     userInfo:nil];
    });

    return moduleBundle;
}

@end
