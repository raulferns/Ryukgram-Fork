# RyukGram v34 — Unified Runtime Browser: realtime resolver + patcher

Base: `Ryukgram-Fork-experimental2.zip` (v33 ABI browsers). Branch: `experimental2`.

The browser stops being a "patch plan viewer". Each symbol is now resolved live,
the sideload-safe strategy is auto-selected, and a working Apply/Revert drives the
same persisted install backends used everywhere in the tweak.

## What's new

### 1. `SCIRuntimeXrefScanner` (new file, `src/Features/Gating/`)
Realtime, in-process, **read-only** ARM64 xref resolver. Given a DATA descriptor's
runtime address it scans the defining image's `__text` for `adrp+add` computing
that address, then the following `bl`, and resolves the callee via `dladdr` →
the concrete consumer/reader (e.g. `IGMobileConfigBooleanValueForInternalUse`).

- Bounded by an instruction budget (default 6M) and a max-hit count.
- Runs off the main thread; completion on main.
- Strictly in-bounds (`__text` only, range-checked). Cannot write or crash code.
- adrp/add/bl decode unit-validated in gcc **and** against the real Instagram binary.

### 2. Engine widened safely (`SCICSymbolStub`)
The MobileConfig descriptor reader-filter now accepts **runtime-confirmed**
descriptors (`+canForceAsParamDescriptor:` = curated list OR dlsym-resolvable).
This is safe to widen because the filter matches by the descriptor **pointer**
against the reader's argument — a symbol that is not the consumed descriptor
simply never matches, so the original value is returned unchanged.

### 3. Interactive resolver + patcher detail screen
`SCICRealtimeDetailViewController` rebuilt as an inset-grouped, glass table:
- **Resolution**: kind, owning image, section, symtab addr, live dlsym addr, ABI.
- **Patch**: auto-selected strategy + working **Apply** / **Revert** + live state/hits.
- **Realtime xref / consumer**: runs the scan on open (DATA) or on demand; lists
  resolved consumers with caller / load site / image.
- **Disassembly / bytes**: lightweight ARM64 decode or hexdump.
- Copy/export of the full resolved report.

Apply routes to the existing persisted backends: fishhook BOOL hardstub, fishhook
typed force (int64/double/string), MobileConfig descriptor reader-filter, and ObjC
IMP swizzle (`SCISymbolBrowserEngine`). Originals are kept for revert.

## Binary validation (Instagram 434 / FBShared, this upload)
- Typed readers (`IGMobileConfigInteger/StringValueForInternalUse`,
  `EasyGatingGetInt32/Int64/Double/CopyString`) are all imported → typed force works.
- DATA descriptors (`ig_is_employee`, …) are referenced by the exec but are opaque;
  a fake-pointer rebind is unsafe, so the resolver uses the reader-filter (safe).
- `SUBSBenefitDataProvider` is a **Swift** class (`_TtC23SUBSBenefitDataProvider…`),
  stripped, not exposed as a classic ObjC class → resolved at runtime; if its calls
  are Swift direct-dispatch there is **no sideload-safe patch** (jailbreak only), and
  the resolver says so honestly rather than installing a no-op.

## Honest sideload boundary (unchanged, enforced)
- No `__TEXT` code patching (W^X). No blind DATA byte-patch without a validated layout.
- C-symbol stubs (BOOL/typed/param) are re-attached **in-session**, not at cold launch
  — forcing MobileConfig/MCI readers at cold launch caused the documented startup
  crash. ObjC overrides do reapply at cold launch. The Apply cell states which applies.
- The xref scan resolves FB-internal consumers reliably; exec-side GOT/Swift-dispatched
  consumers may not resolve and are reported as such.

## v34.1 — build fix + DATA/__TEXT research

### Build fix
`SCICRuntimePatchResolver.m` (from a prior session) called two methods that did
not exist on `SCICSymbolStub`. Added, matching the call-site signatures:
- `+ (BOOL)setParamDescriptorObserve:(BOOL)observe forSymbol:(NSString *)name;`
- `+ (NSUInteger)paramDescriptorCallCountForSymbol:(NSString *)name;`

The descriptor reader-filter now counts a hit on pointer-match even when only
observing (force < 0), so observe + live hit counts work per descriptor.

### Researched DATA / __TEXT landscape (correcting earlier over-conservatism)
- **DATA byte-patch IS viable jailed**: `vm_protect(VM_PROT_READ|WRITE)` + memcpy on
  `__DATA` works on stock iOS (data pages have no execute-signing enforcement).
  Confirmed by no-JB frameworks (Titanox "memory patching, made to work on stock
  iOS", Dobby CodePatch). Needs guards: `__DATA` only, known size, byte backup for revert.
- **fishhook DATA**: GOT / `__nl_symbol_ptr` / `__la_symbol_ptr` rebinding — already used.
- **Inline __TEXT jump in plain sideload (AltStore/Feather)**: needs code pages RWX,
  which needs `CS_DEBUGGED` (the `ptrace(PT_TRACE_ME)` self-trace trick) — Apple
  closed this around iOS 14. No-JB frameworks that "patch __TEXT" do it OFFLINE
  (write a patched binary to Documents and replace+re-inject), not at runtime.
  The runtime no-code-modify option is hardware-breakpoint hooks (ARM64 debug
  registers, ElleKit-style, ~6 max), which still needs a debuggable process.
- **Under jailbreak / TrollStore**: RWX/CS_DEBUGGED is available → inline __TEXT
  hooks work normally. So the resolver should probe the runtime and only offer the
  inline-jump strategy when the process can actually make code RWX.
