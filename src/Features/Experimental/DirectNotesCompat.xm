// Direct Notes experimental reply types + friend map. Gates: igt_directnotes_*.

#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>
#include "../../../modules/fishhook/fishhook.h"

static inline BOOL prefFriendMap(void) { return [SCIUtils getBoolPref:@"igt_directnotes_friendmap"]; }
static inline BOOL prefAudio(void)     { return [SCIUtils getBoolPref:@"igt_directnotes_audio_reply"]; }
static inline BOOL prefAvatar(void)    { return [SCIUtils getBoolPref:@"igt_directnotes_avatar_reply"]; }
static inline BOOL prefGifs(void)      { return [SCIUtils getBoolPref:@"igt_directnotes_gifs_reply"]; }
static inline BOOL prefPhoto(void)     { return [SCIUtils getBoolPref:@"igt_directnotes_photo_reply"]; }

static BOOL rep_friendmap(void) { return prefFriendMap(); }
static BOOL rep_audio(void)     { return prefAudio(); }
static BOOL rep_avatar(void)    { return prefAvatar(); }
static BOOL rep_gifs(void)      { return prefGifs(); }
static BOOL rep_photo(void)     { return prefPhoto(); }

static inline BOOL containsAny(NSString *s, NSArray<NSString *> *needles) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    NSString *lower = s.lowercaseString;
    for (NSString *n in needles) if ([lower containsString:n]) return YES;
    return NO;
}

static BOOL matchesDirectNotes(NSString *name) {
    if (prefFriendMap() && containsAny(name, @[@"friendmap", @"friends_map",
                                               @"ig_ios_friendmap_", @"friendmapenabled"])) return YES;
    if (prefAudio()     && containsAny(name, @[@"audio"])) return YES;
    if (prefAvatar()    && containsAny(name, @[@"avatar"])) return YES;
    if (prefGifs()      && containsAny(name, @[@"gifs", @"sticker"])) return YES;
    if (prefPhoto()     && containsAny(name, @[@"photo"])) return YES;
    return NO;
}

static BOOL (*orig_isIn)(id, SEL, id) = NULL;
static BOOL new_isIn(id self, SEL _cmd, id name) {
    if (matchesDirectNotes(name)) return YES;
    return orig_isIn ? orig_isIn(self, _cmd, name) : NO;
}

%ctor {
    if (!(prefFriendMap() || prefAudio() || prefAvatar() || prefGifs() || prefPhoto())) return;

    struct rebinding binds[] = {
        {"IGDirectNotesFriendMapEnabled",             (void *)rep_friendmap, NULL},
        {"IGDirectNotesEnableAudioNoteReplyType",     (void *)rep_audio,     NULL},
        {"IGDirectNotesEnableAvatarReplyTypes",       (void *)rep_avatar,    NULL},
        {"IGDirectNotesEnableGifsStickersReplyTypes", (void *)rep_gifs,      NULL},
        {"IGDirectNotesEnablePhotoNoteReplyType",     (void *)rep_photo,     NULL},
    };
    rebind_symbols(binds, sizeof(binds) / sizeof(binds[0]));

    // SCI-FIX 2026-06-11: class `IGDirectNotesExperimentHelper` does NOT exist in
    // build 433.0.283 (class-name string absent from the image), so this MSHookMessageEx
    // was a permanent silent no-op. The present class is the Swift exposure helper below
    // (verified via __objc_classname scan). The C-symbol rebinds above are the primary
    // lever and are unaffected. `isInExperiment:` is still guarded by class_getInstanceMethod,
    // so if the selector differs on this class the hook bails cleanly (verify on-device).
    Class helper = NSClassFromString(@"_TtC37IGDirectNotesExperimentExposureHelper37IGDirectNotesExperimentExposureHelper");
    if (!helper) helper = NSClassFromString(@"IGDirectNotesExperimentHelper"); // legacy/older builds
    SEL sel = NSSelectorFromString(@"isInExperiment:");
    if (helper && class_getInstanceMethod(helper, sel)) {
        MSHookMessageEx(helper, sel, (IMP)new_isIn, (IMP *)&orig_isIn);
    }
}
