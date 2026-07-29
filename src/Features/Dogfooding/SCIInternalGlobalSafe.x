// Consolidated new-IG internal/employee implementation.
// Kept as one Logos translation unit; split includes only avoid GitHub Contents
// API size/race issues while preserving exact compile order and static scope.

#include "SCIInternalGlobalSafeParts/part00.inc"
#include "SCIInternalGlobalSafeParts/part01.inc"
#include "SCIInternalGlobalSafeParts/part02.inc"
#include "SCIInternalGlobalSafeParts/part03.inc"
#include "SCIInternalGlobalSafeParts/part04.inc"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdatomic.h>

// MSHookMessageEx/Logos method hooks belong on Objective-C dispatch surfaces.
// Install synchronously from the tweak constructor for launch-linked images.
// If the feature is enabled, one filtered dyld callback covers genuinely late
// IG/FB images. The callback performs only Mach-O filtering, atomics and a C
// dispatch handoff: no Objective-C, timer, global class sweep or hook work.

static _Atomic(BOOL) sSCIInternalFeatureEnabled = NO;
static _Atomic(BOOL) sSCIInternalInstallQueued = NO;
static dispatch_once_t sSCIInternalDyldObserverOnce;

static BOOL SCIInternalGlobalEnabled(void) {
    return SCIInternalMenuOn() || SCIEmployeeInternalMasterOn();
}

static BOOL SCIRefreshInternalGlobalEnabledSnapshot(void) {
    BOOL enabled = SCIInternalGlobalEnabled();
    atomic_store_explicit(&sSCIInternalFeatureEnabled, enabled,
                          memory_order_release);
    return enabled;
}

static const char *SCIImageInstallName(const struct mach_header *mh) {
    if (!mh || mh->magic != MH_MAGIC_64) return NULL;
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *end = cursor + header->sizeofcmds;

    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (cursor + sizeof(struct load_command) > end) break;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command) ||
            cursor + command->cmdsize > end) break;

        if (command->cmd == LC_ID_DYLIB &&
            command->cmdsize >= sizeof(struct dylib_command)) {
            const struct dylib_command *dylibCommand =
                (const struct dylib_command *)command;
            uint32_t offset = dylibCommand->dylib.name.offset;
            if (offset < command->cmdsize) {
                const char *path = (const char *)command + offset;
                const char *leaf = strrchr(path, '/');
                return leaf ? leaf + 1 : path;
            }
        }
        cursor += command->cmdsize;
    }
    return NULL;
}

static BOOL SCIImageMayContainInternalTargets(const struct mach_header *mh) {
    if (!mh) return NO;
    if (mh->filetype == MH_EXECUTE || mh->filetype == MH_BUNDLE) return YES;

    const char *name = SCIImageInstallName(mh);
    if (!name || !name[0]) return NO;

    // Target exact IG/FB class names only inside the installer. The image filter
    // merely avoids waking the installer for unrelated system libraries.
    return strncmp(name, "IG", 2) == 0 ||
           strncmp(name, "FB", 2) == 0 ||
           strstr(name, "Instagram") != NULL ||
           strstr(name, "Meta") != NULL;
}

static void SCIInstallInternalGlobalHooksNow(void) {
    if (!SCIInternalGlobalEnabled()) return;
    SCIInstallInternalGlobalHooksIfNeeded();
}

static void SCIInternalGlobalInstallDeferred(void *context) {
    (void)context;
    atomic_store_explicit(&sSCIInternalInstallQueued, NO,
                          memory_order_release);
    SCIInstallInternalGlobalHooksNow();
}

static void SCIInternalGlobalImageAdded(const struct mach_header *mh,
                                        intptr_t vmaddr_slide) {
    (void)vmaddr_slide;
    SCIAdvanceXPluginsImageGeneration();
    if (!atomic_load_explicit(&sSCIInternalFeatureEnabled,
                              memory_order_acquire)) return;
    if (!SCIImageMayContainInternalTargets(mh)) return;

    BOOL expected = NO;
    if (!atomic_compare_exchange_strong_explicit(&sSCIInternalInstallQueued,
                                                  &expected, YES,
                                                  memory_order_acq_rel,
                                                  memory_order_relaxed)) {
        return;
    }

    dispatch_async_f(dispatch_get_main_queue(), NULL,
                     SCIInternalGlobalInstallDeferred);
}

static void SCIEnsureInternalGlobalDyldObserver(void) {
    if (!atomic_load_explicit(&sSCIInternalFeatureEnabled,
                              memory_order_acquire)) return;
    dispatch_once(&sSCIInternalDyldObserverOnce, ^{
        _dyld_register_func_for_add_image(SCIInternalGlobalImageAdded);
    });
}

void SCIRequestInternalGlobalHooksInstall(void) {
    if ([NSThread isMainThread]) {
        if (!SCIRefreshInternalGlobalEnabledSnapshot()) return;
        SCIInstallInternalGlobalHooksNow();
        SCIEnsureInternalGlobalDyldObserver();
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!SCIRefreshInternalGlobalEnabledSnapshot()) return;
        SCIInstallInternalGlobalHooksNow();
        SCIEnsureInternalGlobalDyldObserver();
    });
}

NSString *SCIInternalGlobalHookStatus(void) {
    NSUInteger mcCount = 0;
    mcCount += orig_MCGetBool != NULL;
    mcCount += orig_MCGetBoolDefault != NULL;
    mcCount += orig_MCGetBoolOptions != NULL;
    mcCount += orig_MCGetBoolOptionsDefault != NULL;
    mcCount += orig_MCGetBoolNoLog != NULL;
    mcCount += orig_MCGetBoolNoLogDefault != NULL;

    NSUInteger menuCount = 0;
    menuCount += orig_SafeBugMenuLegacy != NULL;
    menuCount += orig_SafeBugMenuCurrent != NULL;
    menuCount += orig_SafeBugMenuViewDidLoad != NULL;
    menuCount += orig_SafeBugMenuViewDidAppear != NULL;
    menuCount += orig_SafeBugMenuDidSelect != NULL;

    NSUInteger openerCount = 0;
    openerCount += orig_TryOpenNativeDogfoodSettings != NULL;
    openerCount += orig_OpenDogfoodingSettingsVC != NULL;
    openerCount += orig_OpenInstagramDebugMenu != NULL;

    return [NSString stringWithFormat:
        @"Employee master: %@\n"
         @"Internal menu: %@\n"
         @"MobileConfig employee readers: %lu/6\n"
         @"Bug Reporter hooks: %lu/5\n"
         @"Native opener bridges: %lu/3\n"
         @"XPlugins internal_only payload: %@\n"
         @"XPlugins Dogfooding payload: %@",
        SCIEmployeeInternalMasterOn() ? @"ON" : @"OFF",
        SCIInternalMenuOn() ? @"ON" : @"OFF",
        (unsigned long)mcCount,
        (unsigned long)menuCount,
        (unsigned long)openerCount,
        SCIInternalOnlyPayloadAvailable() ? @"available" : @"empty/unavailable",
        SCIDogfoodAssistantPayloadAvailable() ? @"available" : @"empty/unavailable"];
}

// %ctor runs after this dependent dylib is loaded and before main. Install the
// exact launch-linked targets only when the persisted feature is enabled. The
// dyld observer is likewise registered only on first enable, not for stock mode.
%ctor {
    @autoreleasepool {
        if (SCIRefreshInternalGlobalEnabledSnapshot()) {
            SCIInstallInternalGlobalHooksNow();
            SCIEnsureInternalGlobalDyldObserver();
        }
    }
}
