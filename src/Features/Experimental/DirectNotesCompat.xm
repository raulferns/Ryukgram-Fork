// Direct Notes Maps / Friend Map only. The reply-type flags were removed from
// the UI because they are no longer reliable on current IG builds.

#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>
#include "../../../modules/fishhook/fishhook.h"

static BOOL gFriendMapEnabled = NO;

static BOOL rep_friendmap(void) { return gFriendMapEnabled; }

static inline BOOL containsAny(NSString *s, NSArray<NSString *> *needles) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    NSString *lower = s.lowercaseString;
    for (NSString *n in needles) if ([lower containsString:n]) return YES;
    return NO;
}

static BOOL matchesDirectNotesMaps(NSString *name) {
    if (!gFriendMapEnabled) return NO;
    return containsAny(name, @[@"friendmap", @"friends_map", @"ig_ios_friendmap_", @"friendmapenabled"]);
}

static BOOL (*orig_isIn)(id, SEL, id) = NULL;
static BOOL new_isIn(id self, SEL _cmd, id name) {
    if (matchesDirectNotesMaps(name)) return YES;
    return orig_isIn ? orig_isIn(self, _cmd, name) : NO;
}

%ctor {
    gFriendMapEnabled = [SCIUtils getBoolPref:@"igt_directnotes_friendmap"];
    if (!gFriendMapEnabled) return;

    struct rebinding binds[] = {
        {"IGDirectNotesFriendMapEnabled", (void *)rep_friendmap, NULL},
    };
    rebind_symbols(binds, sizeof(binds) / sizeof(binds[0]));

    Class helper = NSClassFromString(@"_TtC34IGDirectNotesExperimentHelperSwift29IGDirectNotesExperimentHelper") ?: NSClassFromString(@"IGDirectNotesExperimentHelper");
    SEL sel = NSSelectorFromString(@"isInExperiment:");
    if (helper && class_getInstanceMethod(helper, sel)) {
        MSHookMessageEx(helper, sel, (IMP)new_isIn, (IMP *)&orig_isIn);
    }
}
