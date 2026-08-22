#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "../../../modules/fishhook/fishhook.h"

// Legacy MobileConfig call-site telemetry executes backtrace() once for every
// newly observed PID. Instagram can evaluate thousands of distinct parameters
// before its first frame, which turns diagnostics into launch work.
//
// Rebind only RyukGram.dylib's own backtrace import. This does not patch the
// Instagram/FBSharedFramework executable pages and does not affect system or
// host-app callers. Runtime overrides themselves do not depend on a backtrace.

static int RYGMobileConfigBacktraceDisabled(void **buffer, int size) {
    (void)buffer;
    (void)size;
    return 0;
}

__attribute__((constructor(100))) static void RYGDisableRyukGramBacktraceImport(void) {
    Dl_info info = {0};
    if (!dladdr((const void *)&RYGDisableRyukGramBacktraceImport, &info) || !info.dli_fbase) return;
    const struct mach_header *ourHeader = (const struct mach_header *)info.dli_fbase;
    intptr_t slide = 0;
    BOOL found = NO;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        if (_dyld_get_image_header(index) == ourHeader) {
            slide = _dyld_get_image_vmaddr_slide(index);
            found = YES;
            break;
        }
    }
    if (!found) return;
    struct rebinding binding = {
        .name = "backtrace",
        .replacement = (void *)&RYGMobileConfigBacktraceDisabled,
        .replaced = NULL,
    };
    (void)rebind_symbols_image((void *)ourHeader, slide, &binding, 1);
}
