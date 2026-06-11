// Force-enable Homecoming nav experiment. Gate: igt_homecoming.

#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>

static NSString *expNameOf(id obj) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), "_experimentGroupName");
    if (!iv) iv = class_getInstanceVariable(object_getClass(obj), "_experimentName");
    if (!iv) return nil;
    @try {
        id v = object_getIvar(obj, iv);
        if ([v isKindOfClass:[NSString class]]) return v;
    } @catch (__unused id e) {}
    return nil;
}

static inline BOOL matchesHomecoming(NSString *s) {
    return [s isKindOfClass:[NSString class]] && s.length &&
           [s.lowercaseString containsString:@"homecoming"];
}

static BOOL (*orig_meta_isIn)(id, SEL) = NULL;
static BOOL new_meta_isIn(id self, SEL _cmd) {
    if (matchesHomecoming(expNameOf(self))) return YES;
    return orig_meta_isIn ? orig_meta_isIn(self, _cmd) : NO;
}

static BOOL (*orig_family_isIn)(id, SEL) = NULL;
static BOOL new_family_isIn(id self, SEL _cmd) {
    if (matchesHomecoming(expNameOf(self))) return YES;
    return orig_family_isIn ? orig_family_isIn(self, _cmd) : NO;
}

static BOOL (*orig_lid_enabled)(id, SEL, NSString *) = NULL;
static BOOL new_lid_enabled(id self, SEL _cmd, NSString *name) {
    if (matchesHomecoming(name)) return YES;
    return orig_lid_enabled ? orig_lid_enabled(self, _cmd, name) : NO;
}

static BOOL (*orig_nav_isHC)(id, SEL) = NULL;
static BOOL new_nav_isHC(id self, SEL _cmd) { return YES; }

static void hook(Class cls, NSString *selName, IMP newImp, IMP *origOut) {
    if (!cls) return;
    SEL s = NSSelectorFromString(selName);
    if (!class_getInstanceMethod(cls, s)) return;
    MSHookMessageEx(cls, s, newImp, origOut);
}

%ctor {
    if (![SCIUtils getBoolPref:@"igt_homecoming"]) return;

    // SCI-FIX 2026-06-11: VERIFIED against build 433.0.283 — only `LIDExperimentGenerator`
    // is present in this image. `MetaLocalExperiment`, `FamilyLocalExperiment` and
    // `_TtC18IGNavConfiguration18IGNavConfiguration` are ABSENT (class-name strings not in
    // the binary), so those three hooks are inert silent no-ops here. They are kept
    // nil-guarded for older binaries, but on 433 the *only* effective lever below is the
    // LIDExperimentGenerator -isExperimentEnabled: hook. If Homecoming still does not
    // surface, the real gate is elsewhere (search the image for the realized config class
    // that owns -isHomecomingEnabled, 53 xrefs) — do NOT assume these names work.
    hook(NSClassFromString(@"MetaLocalExperiment"),   @"isInExperiment",
         (IMP)new_meta_isIn,   (IMP *)&orig_meta_isIn);   // inert on 433 (class absent)
    hook(NSClassFromString(@"FamilyLocalExperiment"), @"isInExperiment",
         (IMP)new_family_isIn, (IMP *)&orig_family_isIn); // inert on 433 (class absent)
    hook(NSClassFromString(@"LIDExperimentGenerator"), @"isExperimentEnabled:",
         (IMP)new_lid_enabled, (IMP *)&orig_lid_enabled); // PRESENT — effective lever
    hook(NSClassFromString(@"_TtC18IGNavConfiguration18IGNavConfiguration"),
         @"isHomecomingEnabled", (IMP)new_nav_isHC, (IMP *)&orig_nav_isHC); // inert on 433 (class absent)
}
