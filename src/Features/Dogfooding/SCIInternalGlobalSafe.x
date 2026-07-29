// Consolidated new-IG internal/employee implementation.
// Kept as one Logos translation unit; split includes only avoid GitHub Contents
// API size/race issues while preserving exact compile order and static scope.

#include "SCIInternalGlobalSafeParts/part00.inc"
#include "SCIInternalGlobalSafeParts/part01.inc"
#include "SCIInternalGlobalSafeParts/part02.inc"
#include "SCIInternalGlobalSafeParts/part03.inc"
#include "SCIInternalGlobalSafeParts/part04.inc"

// Logos directives must live in the .x translation unit. The C preprocessor
// expands the .inc files only after Logos has parsed this file, so placing %ctor
// inside an included fragment would leave raw Logos syntax for clang.
%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            SCIInstallInternalGlobalHooksIfNeeded();
        });
    }
}
