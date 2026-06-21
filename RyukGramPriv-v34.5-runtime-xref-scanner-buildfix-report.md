# RyukGram v34.5 — Runtime xref scanner buildfix

## Root cause

v34.4 already contained the runtime xref scanner implementation:

- `src/Features/Gating/SCIRuntimeXrefScanner.h`
- `src/Features/Gating/SCIRuntimeXrefScanner.m`

The failing iSH/GitHub command only added:

- `SCISymbolBrowserEngine.h/.m`
- `SCICSymbolStub.h/.m`
- `SCISymbolsBrowserViewController.m`
- `SCIDefaults.m`

It did **not** add the new scanner files to Git. The branch therefore had `SCISymbolsBrowserViewController.m` importing `SCIRuntimeXrefScanner.h`, while the header itself was missing from the commit. That is why Theos failed with:

```text
fatal error: '../Features/Gating/SCIRuntimeXrefScanner.h' file not found
```

## What is in the scanner

`SCIRuntimeXrefScanner` is a bounded, read-only ARM64 runtime resolver. It resolves DATA consumers by scanning the owning image `__TEXT,__text` for:

```text
adrp/add loading target DATA address → nearby bl consumer/reader
```

It returns live `SCIXrefHit` entries with:

- load PC;
- call PC;
- resolved callee address;
- callee symbol via `dladdr`;
- caller symbol via `dladdr`;
- owning image name;
- budget status.

The detail screen uses the hits to upgrade strategy automatically, for example:

```text
DATA descriptor + consumer IGMobileConfigBooleanValueForInternalUse
→ MobileConfig descriptor reader-filter
→ Apply patch / Revert patch / persisted toggle
```

## Guardrails

- No writes to `__TEXT`.
- No inline code patch in sideload.
- Scan runs off-main.
- Scan is budgeted by instruction count and hit count.
- Reads only mapped `__TEXT,__text` bounds.
- Used for resolver decisions and UI state; actual hook install still routes through the existing proven backends.

## Files to commit

```text
src/Features/Gating/SCIRuntimeXrefScanner.h
src/Features/Gating/SCIRuntimeXrefScanner.m
src/Features/Dogfooding/SCISymbolBrowserEngine.h
src/Features/Dogfooding/SCISymbolBrowserEngine.m
src/Features/Gating/SCICSymbolStub.h
src/Features/Gating/SCICSymbolStub.m
src/Settings/SCISymbolsBrowserViewController.m
src/SCIDefaults.m
```
