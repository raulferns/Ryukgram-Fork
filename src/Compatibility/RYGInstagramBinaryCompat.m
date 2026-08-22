#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "../Utils.h"
#import "../../modules/fishhook/fishhook.h"

// Runtime compatibility layer for the symbols actually exported/imported by
// Instagram(9) + FBSharedFramework(20260821-132949). It deliberately does not
// patch signed __TEXT pages; only the main executable's import slots are rebound.
typedef BOOL (*RYGIGContextBoolFn)(id context);
typedef NSInteger (*RYGIGContextStyleFn)(id context);

static RYGIGContextBoolFn gRYGNativeFloatingTabBarEnabled;
static RYGIGContextBoolFn gRYGNativeDynamicSizingEnabled;
static RYGIGContextBoolFn gRYGNativeHomecomingFloatingEnabled;
static RYGIGContextStyleFn gRYGNativeTabBarStyleForLauncherSet;
static void *gRYGPreviousFloatingSlot;
static void *gRYGPreviousDynamicSlot;
static void *gRYGPreviousHomecomingSlot;
static void *gRYGPreviousStyleSlot;
static BOOL gRYGInstagramBinaryCompatInstalled;

static BOOL RYGIGForceLiquidGlassOff(void) {
    return [RYGUtils getBoolPref:@"liquid_glass_force_off"];
}

static BOOL RYGIGForceLiquidGlassSurfaces(void) {
    return !RYGIGForceLiquidGlassOff() && [RYGUtils getBoolPref:@"liquid_glass_surfaces"];
}

static BOOL RYGIGFloatingTabBarEnabledReplacement(id context) {
    if (RYGIGForceLiquidGlassOff()) return NO;
    if (RYGIGForceLiquidGlassSurfaces()) return YES;
    return gRYGNativeFloatingTabBarEnabled ? gRYGNativeFloatingTabBarEnabled(context) : NO;
}

static NSInteger RYGIGTabBarStyleForLauncherSetReplacement(id context) {
    if (RYGIGForceLiquidGlassOff()) return 0;
    if (RYGIGForceLiquidGlassSurfaces()) return 1;
    return gRYGNativeTabBarStyleForLauncherSet ? gRYGNativeTabBarStyleForLauncherSet(context) : 0;
}

static BOOL RYGIGTabBarDynamicSizingEnabledReplacement(id context) {
    if (RYGIGForceLiquidGlassOff()) return NO;
    if (RYGIGForceLiquidGlassSurfaces()) {
        // The current framework evaluates dynamic sizing only after the floating
        // gate succeeds. Preserve that dependency instead of forcing an
        // impossible combination of independent booleans.
        return RYGIGFloatingTabBarEnabledReplacement(context);
    }
    return gRYGNativeDynamicSizingEnabled ? gRYGNativeDynamicSizingEnabled(context) : NO;
}

static BOOL RYGIGTabBarHomecomingWithFloatingTabEnabledReplacement(id context) {
    if (RYGIGForceLiquidGlassOff()) return NO;
    if (RYGIGForceLiquidGlassSurfaces()) {
        return RYGIGFloatingTabBarEnabledReplacement(context);
    }
    return gRYGNativeHomecomingFloatingEnabled ? gRYGNativeHomecomingFloatingEnabled(context) : NO;
}

static BOOL RYGIGMainExecutableImage(const struct mach_header **headerOut, intptr_t *slideOut) {
    if (!headerOut || !slideOut) return NO;
    NSString *wanted = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    if (!wanted.length) return NO;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) continue;
        NSString *path = [[NSString stringWithUTF8String:raw] stringByStandardizingPath];
        if (![path isEqualToString:wanted]) continue;
        *headerOut = _dyld_get_image_header(index);
        *slideOut = _dyld_get_image_vmaddr_slide(index);
        return *headerOut != NULL;
    }
    return NO;
}

static void RYGInstallInstagramBinaryCompat(void) {
    @synchronized(RYGUtils.class) {
        if (gRYGInstagramBinaryCompatInstalled) return;

        BOOL forceOff = RYGIGForceLiquidGlassOff();
        BOOL forceSurfaces = RYGIGForceLiquidGlassSurfaces();
        if (!forceOff && !forceSurfaces) {
            gRYGInstagramBinaryCompatInstalled = YES;
            return;
        }

        gRYGNativeFloatingTabBarEnabled = (RYGIGContextBoolFn)dlsym(RTLD_DEFAULT, "IGFloatingTabBarEnabled");
        gRYGNativeDynamicSizingEnabled = (RYGIGContextBoolFn)dlsym(RTLD_DEFAULT, "IGTabBarDynamicSizingEnabled");
        gRYGNativeHomecomingFloatingEnabled = (RYGIGContextBoolFn)dlsym(RTLD_DEFAULT, "IGTabBarHomecomingWithFloatingTabEnabled");
        gRYGNativeTabBarStyleForLauncherSet = (RYGIGContextStyleFn)dlsym(RTLD_DEFAULT, "IGTabBarStyleForLauncherSet");

        const struct mach_header *mainHeader = NULL;
        intptr_t mainSlide = 0;
        if (!RYGIGMainExecutableImage(&mainHeader, &mainSlide)) return;

        struct rebinding bindings[4];
        void **replacedSlots[4];
        size_t count = 0;
        if (gRYGNativeFloatingTabBarEnabled) {
            replacedSlots[count] = &gRYGPreviousFloatingSlot;
            bindings[count++] = (struct rebinding){"IGFloatingTabBarEnabled", (void *)RYGIGFloatingTabBarEnabledReplacement, &gRYGPreviousFloatingSlot};
        }
        if (gRYGNativeDynamicSizingEnabled) {
            replacedSlots[count] = &gRYGPreviousDynamicSlot;
            bindings[count++] = (struct rebinding){"IGTabBarDynamicSizingEnabled", (void *)RYGIGTabBarDynamicSizingEnabledReplacement, &gRYGPreviousDynamicSlot};
        }
        if (gRYGNativeHomecomingFloatingEnabled) {
            replacedSlots[count] = &gRYGPreviousHomecomingSlot;
            bindings[count++] = (struct rebinding){"IGTabBarHomecomingWithFloatingTabEnabled", (void *)RYGIGTabBarHomecomingWithFloatingTabEnabledReplacement, &gRYGPreviousHomecomingSlot};
        }
        if (gRYGNativeTabBarStyleForLauncherSet) {
            replacedSlots[count] = &gRYGPreviousStyleSlot;
            bindings[count++] = (struct rebinding){"IGTabBarStyleForLauncherSet", (void *)RYGIGTabBarStyleForLauncherSetReplacement, &gRYGPreviousStyleSlot};
        }
        if (!count) return;

        if (rebind_symbols_image((void *)mainHeader, mainSlide, bindings, count) != 0) return;
        for (size_t index = 0; index < count; index++) {
            if (!*replacedSlots[index]) return;
        }
        gRYGInstagramBinaryCompatInstalled = YES;
    }
}

__attribute__((constructor)) static void RYGInstagramBinaryCompatConstructor(void) {
    // Run after the tweak constructors have returned so this ABI-correct layer
    // deterministically supersedes legacy rebinding registrations. Re-apply at
    // did-finish-launching in case the target import slots were bound lazily.
    dispatch_async(dispatch_get_main_queue(), ^{
        RYGInstallInstagramBinaryCompat();
    });
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        RYGInstallInstagramBinaryCompat();
    }];
}
