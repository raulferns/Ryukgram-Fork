# iOS sideload hook strategy

This note records the hook-selection and timing rules used by the Instagram
internal/employee implementation. The mechanism is selected from the actual
call/dispatch surface, not from the popularity of a hook library.

## 1. Objective-C message dispatch

Examples in this project:

- `FBMobileConfigContextManager -getBool:` variants
- `IGBugReportMenuViewController` initializers
- `-viewDidLoad`, `-viewDidAppear:` and table selection
- local `-isEmployee` getters

Use:

- `MSHookMessageEx`, or the equivalent Logos/libhooker/ElleKit Objective-C API
- exact class and selector
- exact type-encoding validation before installation
- one stored original IMP per class/selector

Why:

- the call is resolved through Objective-C method dispatch
- the class method list lives in writable runtime data
- no target `__TEXT` instruction needs to be modified
- `MSHookMessageEx` preserves superclass/original-call behavior better than a
  hand-written `method_setImplementation` swap

Timing:

- install synchronously in the tweak constructor when the target image is a
  normal launch dependency
- if a target image is genuinely loaded later, react to that image-load event;
  do not guess with `dispatch_after`
- when a preference is enabled at runtime, call the idempotent installer
  explicitly from the toggle action

## 2. Imported C functions

Examples:

- a caller reaches an external symbol through Mach-O lazy/non-lazy symbol
  pointers

Possible mechanisms:

- fishhook
- Dobby `DobbyImportTableReplace`
- dyld interposing where its load/interposition semantics fit

Use only after proving that the relevant callers use an imported symbol pointer.
These mechanisms do not intercept:

- a local/private function called directly by address
- an inlined function
- a Swift/C function whose callsite was statically resolved
- a data descriptor that merely has a function-like name

On arm64e/newer iOS, pointer-authenticated and read-only import-pointer sections
must be treated as a separate compatibility concern. A generic fishhook drop-in
is not automatically safe for every `__AUTH_CONST`/`__DATA_CONST` layout.

## 3. Native inline function hooks

Examples of APIs in this family:

- `MSHookFunction`
- Dobby `DobbyHook`
- libhooker `LHHookFunctions`
- ElleKit's Substrate-compatible C hook API
- Orion `FunctionHook`
- Frida `Interceptor`

All of these ultimately redirect execution at or near the target native code.
The implementation may use a branch trampoline, relocated prologue, breakpoint
exception, or another code-patching technique, but it is still an inline/code
hook family.

For this sideload build, do not use this family on Instagram/FB `__TEXT` unless
there is device-specific proof that the injector, signing mode, target page and
hook engine preserve executable-page validity. Replacing MSHookFunction with
DobbyHook does not by itself solve a `CODESIGNING / Invalid Page` termination.

## 4. Data, descriptors and provider tables

The audited `_ig_is_employee` / `_ig_is_employee_or_test_user` objects are data
descriptors, not callable `BOOL` functions. They must not be passed to a native
function hook API.

The XPlugins provider used here returns a two-register structure:

```c
typedef struct {
    const void *data;
    uintptr_t count;
} SCIXPluginsDataPair;
```

Rules:

- resolve and call the real provider with its real ABI
- never replace the provider with a Boolean or sentinel pointer
- never permanently cache an early "symbol/provider unavailable" result when
  the exporting image or session graph may appear later
- prefer hooking the exact validated consumers when the descriptor layout is
  not a stable public ABI

## 5. C++ virtual and Swift witness dispatch

Vtable or witness-table replacement is a distinct data-pointer hook family. It
can be appropriate only when disassembly proves the call is dispatched through
that exact table.

It is not the default for this project because:

- Swift metadata/witness layouts are ABI-sensitive
- arm64e pointer authentication can apply to function pointers
- many Swift calls are statically dispatched and never consult a witness table
- replacing a table entry does not cover direct callsites

## 6. Per-instance and forwarding techniques

Other legitimate techniques include:

- per-instance `isa` subclassing / `object_setClass`
- `objc_msgForward` forwarding
- `method_setImplementation`, `method_exchangeImplementations` or
  `imp_implementationWithBlock`
- block/function-pointer field replacement

These are useful for narrowly scoped objects or code owned by the tweak. They
are not a substitute for an exact class-wide method hook when Instagram creates
many independent instances.

## 7. Analysis-only instrumentation

Frida Gum, Stalker, breakpoint/exception interception and similar engines are
excellent for discovery, call tracing and ABI confirmation. They are too heavy
and too dependent on runtime code-modification policy to be the default shipping
mechanism for this rootless sideload tweak.

## 8. Timing used by Internal Global

The implementation now follows this sequence:

1. If the persisted feature is off, the constructor installs nothing and does
   not register the image observer.
2. If enabled, the constructor synchronously installs exact Objective-C targets
   already registered by the runtime.
3. A single filtered dyld add-image callback is registered only on first enable.
4. The dyld callback performs no Objective-C work. It only filters the Mach-O
   image, coalesces through atomics and asynchronously hands work to the main
   queue after the callback returns.
5. Toggle actions explicitly refresh the enabled snapshot and invoke the
   idempotent installer.
6. XPlugins symbol and payload absence is rechecked instead of being cached as a
   permanent constructor-time failure.

## Primary references reviewed

- Apple Objective-C Runtime documentation (`method_setImplementation`, class
  lookup and runtime APIs)
- Apple `dyld(3)` documentation for add-image callbacks
- Apple dynamic-library initialization and launch-time guidance
- Theos Logos syntax and hook initialization documentation
- Cydia Substrate `MSHookMessageEx`, `MSHookFunction` and `MSHookClassPair`
- facebook/fishhook implementation and open arm64e/read-only-section issues
- Dobby public API and ImportTableReplace plugin
- ElleKit public README and Substrate/libhooker compatibility notes
- libhooker API reference
- Orion ClassHook/FunctionHook documentation
- Frida Interceptor, module-observer and code-signing-policy documentation
