#!/usr/bin/env python3
"""Fail fast on dogfood architecture/performance regressions before Theos."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"source validation error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(path: str) -> str:
    file = ROOT / path
    if not file.is_file():
        fail(f"required implementation missing: {path}")
    return file.read_text(encoding="utf-8", errors="replace")


def require(text: str, markers: tuple[str, ...], owner: str) -> None:
    for marker in markers:
        if marker not in text:
            fail(f"{owner} contract marker missing: {marker}")


def logos_orig_tail(line: str) -> str | None:
    for match in re.finditer(r"%orig\b", line):
        cursor = match.end()
        while cursor < len(line) and line[cursor].isspace():
            cursor += 1
        if cursor < len(line) and line[cursor] == "(":
            depth = 0
            while cursor < len(line):
                if line[cursor] == "(": depth += 1
                elif line[cursor] == ")":
                    depth -= 1
                    if depth == 0:
                        cursor += 1
                        break
                cursor += 1
        tail = line[cursor:]
        if not re.fullmatch(r"\s*;\s*", tail):
            return tail
    return None


makefile = read("Makefile")
require(makefile, ("TARGET := iphone:clang:26.5:15.0", "-include src/RYGPrefix.h", "src/Compatibility"), "build")
if (ROOT / "src/BundleAssets/ryg_mc_names.bin").exists():
    fail("preloaded MobileConfig name catalog must not ship")
for legacy_module in (ROOT / "modules/zxPluginsInject", ROOT / "modules/SideloadPatch"):
    if legacy_module.exists() and any(legacy_module.iterdir()):
        fail(f"separate sideload helper returned: {legacy_module.relative_to(ROOT)}")

# Runtime Browser: discovery is on-demand; persistence has one bounded owner.
# Persisted exact hooks may act during startup, so their invocation path must be
# atomic-only rather than deferred until after the gate was already evaluated.
manager_h = read("src/Debug/RYGRuntimeHookManager.h")
manager = read("src/Debug/RYGRuntimeHookManager.m")
bulk = read("src/Debug/RYGRuntimeBulkSessionOwner.m")
browser = read("src/Debug/RYGFastRuntimeBrowserViewController.m")
engine = read("src/Debug/RYGRuntimeBrowserEngine.m")
value_store = read("src/Debug/RYGRuntimeValueStore.m")
require(manager_h, ("RYGRuntimeHookManager", "setSessionOverride"), "runtime hook manager header")
require(manager, (
    "ryg_runtime_bool_hook_specs_v7",
    "ryg_runtime_legacy_bulk_cleanup_v8",
    "kRYGRuntimePersistentSpecLimit = 128",
    "kRYGRuntimeCPersistentSpecLimit = 8",
    "RYGRuntimeHotState",
    "forcedSet",
    "forcedValue",
    "nativeValue",
    "RYGHookHotResult",
    "atomic_exchange_explicit",
    "gRYGRuntimePending",
    "gRYGCPending",
    "RYGHookDirectMethod",
    "RYGHookInstallExact",
    "RYGHasPendingRestore",
    "setSessionOverride",
    "RYGPurgeUntouchedLegacyBulkIfNeeded",
    "constructor(205)",
    "No second timer replay here",
    "_dyld_register_func_for_add_image",
), "runtime hook manager")
if "objc_getClassList" in manager or "objc_copyClassNamesForImage" in manager:
    fail("runtime persistence owner must replay exact identities, never discover classes")
if "gRYGRuntimePending.allObjects" not in manager:
    fail("runtime replay must iterate unresolved identities only")
if "RYGHookOverride(strongRecord" in manager or "RYGHookRememberNative(strongRecord" in manager:
    fail("persisted runtime trampoline reintroduced dictionary/lock lookup per invocation")
if "RYGRuntimeRestoreLaunchGate" in manager or (ROOT / "src/Debug/RYGRuntimeRestoreLaunchGate.m").exists():
    fail("generic persisted hooks must preserve startup semantics; post-active launch gate returned")
require(bulk, ("setSessionOverride", "session only", "revealAllVisibilityRows"), "bulk visibility")
if "setOverride:desired" in bulk:
    fail("Reveal All must not persist a bulk generic hook set")
require(browser, (
    "objc_copyClassNamesForImage",
    "membersForClassName",
    "Cross-class selector scan is on-demand",
    "Force On",
    "Force Off",
    "Use Native",
    "machOSymbolsForImagePath",
    "applyAllPersistedRuntimeValues",
    "Edit typed override",
), "Runtime Browser")
if "objc_getClassList" in browser or "_dyld_register_func_for_add_image" in browser:
    fail("Runtime Browser UI reintroduced process-global/startup discovery")
if "__attribute__((constructor))" in engine or "_dyld_register_func_for_add_image" in engine:
    fail("Runtime Browser engine must remain discovery/presentation-only")
require(engine, ("RYGTypedGetterType", "hookableValue", "valueTypeCode"), "typed Runtime Browser engine")
require(value_store, (
    "ryg_runtime_typed_value_overrides_v1",
    "RYGRuntimeValueEncodedObjectSpec",
    "RYGRuntimeValueReplacement",
    "MSHookMessageEx",
    "RYGRuntimeValueReinstallPersistedHooks",
    "method_getNumberOfArguments(method) != 2",
), "typed runtime value store")
for type_case in ("case 'B':", "case 'q':", "case 'Q':", "case 'f':", "case 'd':", "case '@':"):
    if type_case not in value_store:
        fail(f"typed runtime value store ABI missing: {type_case}")
if "__attribute__((constructor" in value_store:
    fail("generic typed runtime-value hooks must be applied explicitly, not from cold launch")
if "synchronize]" in value_store:
    fail("typed runtime-value persistence must not synchronously flush NSUserDefaults")

# Developer screens must not be a prerequisite for restore.
hub = read("src/Debug/RYGDeveloperHubViewController.m")
topic = read("src/Debug/RYGDeveloperTopicViewController.m")
if "activatePersistedNativeFeatures" in hub:
    fail("opening Developer Hub must not perform persistence restore")
require(topic, (
    "_TtC17IGBugReporterMenu29IGBugReportMenuViewController",
    "_TtC20IGDogfoodingSettings34IGDogfoodingSettingsViewController",
    "_TtC27IGPersistentStoryTrayGating38IGPersistentStoryTrayGatingStaticFuncs",
    "_TtC18IGNavConfiguration25IGHomecomingConfiguration",
    "isDynamicTabStoryGridEnabled",
    "No MobileConfig prepare/reload/reapply occurs here",
    "showDebugMenuWithEntryPoint:",
    "IGWindow builds the real device + user session dependency graph",
), "Developer exact owner")
if "objc_getClassList" in topic or "RYGFindExactBoolSelector" in topic:
    fail("Developer screen reintroduced global class discovery")
if "sessionBrowserViewController:userSession:" in topic:
    fail("Dogfooding Assistant Swift-only API was fabricated as an Objective-C selector")
if "overrideLauncherWithUserSession:launcherName:parametersToValues:" in topic:
    fail("Swift-only Dogfooding Assistant launcher was fabricated as an Objective-C hook")
tweak = read("src/Tweak.x")
if "RYGDebugBlockGroup" in tweak or re.search(r"%hook\s+IGWindow.*?-\s*\([^)]*\)showDebugMenu\s*\{\s*\}", tweak, re.S):
    fail("native IGWindow Debug menu was disabled again")
if re.search(r"%hook\s+IGBugReportUploader.*?return\s+nil\s*;", tweak, re.S):
    fail("native Bug Report uploader was disabled again")
activation = re.search(r"\+ \(void\)activatePersistedNativeFeatures\s*\{(?P<body>.*?)\n\}\n\n- \(instancetype\)initWithSurface", topic, re.S)
if not activation:
    fail("could not validate Developer persisted activation body")
for forbidden in (" prepare]", "reloadFromRuntime", "reapplyOverridesToNativeTable"):
    if forbidden in activation.group("body"):
        fail(f"Developer startup restore must not enumerate/reapply MobileConfig: {forbidden}")

# MobileConfig: the app-launch getter path must be lock-free and allocation-free.
mc_header = read("src/Features/ExpFlags/RYGMobileConfig.h")
for type_name, discriminator in (("RYGMCTypeBool",1),("RYGMCTypeInt",2),("RYGMCTypeString",3),("RYGMCTypeDouble",4)):
    if not re.search(rf"\b{type_name}\s*=\s*{discriminator}\b", mc_header):
        fail(f"MobileConfig discriminator drifted: {type_name} must equal {discriminator}")
mc = read("src/Features/ExpFlags/RYGMobileConfig.xm")
require(mc, (
    "_ZN12mobileconfig17typeFromParameterEy",
    "_ZN12mobileconfig23kMobileConfigParamsListE",
    "setOverrideForParam:andValue:",
    "removeOverrideForParam:",
    "rygMethodIsSetOverride",
    "if (returnsBool)",
), "MobileConfig")
if "rygMethodIsVoidQObject" in mc:
    fail("StartupConfigs setOverride reverted to the obsolete void-only ABI")
mc_owner = read("src/Features/ExpFlags/RYGMobileConfigHookOwner.m")
require(mc_owner, (
    "RYG_MC_HOT_CAPACITY",
    "gRYGMCHotSlots",
    "RYGMCHotFindSlot",
    "RYGMCHotLoadDiskSnapshotOnce",
    "RYGMCOwnedOverride",
    "atomic_load_explicit",
    "RYGMCIMPBelongsToRyukGram",
    "gRYGMCHooksInstalled",
    "Capture native IMPs before the legacy Logos constructor",
), "MobileConfig hot-path owner")
match = re.search(r"static id RYGMCOwnedOverride\([^)]*\)\s*\{(?P<body>.*?)\n\}", mc_owner, re.S)
if not match:
    fail("could not inspect MobileConfig hot getter lookup")
for forbidden in (
    "NSNumber", "NSDictionary", "NSMutableDictionary", "os_unfair_lock",
    "RYGMobileConfig.shared", "class_getInstanceVariable", "dictionaryWithContentsOfFile",
    "NSUserDefaults", "backtrace", "dladdr", "reapplyOverridesToNativeTable",
):
    if forbidden in match.group("body"):
        fail(f"MobileConfig getter hot path performs expensive work: {forbidden}")
if "reapplyOverridesToNativeTable" in mc_owner:
    fail("MobileConfig hook-install owner must not reapply the full native override table")

# The old Logos MobileConfig getter owner remains source-compatible only; it may
# not stack on top of the RAM owner during the constructor window.
mc_legacy_gate = read("src/Features/ExpFlags/RYGMobileConfigLegacyHookGate.m")
require(mc_legacy_gate, (
    "constructor(90)",
    "ryg_metaconfig_enabled",
    "method_exchangeImplementations",
    "UIApplicationDidFinishLaunchingNotification",
    "RYGMCLegacyGateRemove",
), "legacy MobileConfig hook gate")
if "setBool:" in mc_legacy_gate or "setObject:" in mc_legacy_gate:
    fail("legacy MobileConfig gate must never mutate the user's saved preference")
mc_backtrace = read("src/Features/ExpFlags/RYGMobileConfigBacktraceGuard.m")
require(mc_backtrace, ("rebind_symbols_image", '.name = \"backtrace\"', "RYGMobileConfigBacktraceDisabled", "constructor(100)"), "MobileConfig callsite guard")

mc_bridge = read("src/Features/ExpFlags/RYGMobileConfigBridge.m")
if "containerURLForSecurityApplicationGroupIdentifier" in mc_bridge:
    fail("guessed MobileConfig App Group fallback returned")
if 'hasSuffix:@".data"' not in mc_bridge:
    fail("native MobileConfig data-directory contract missing")
if "RYGBridgePreferredWritableGroupRoot" in mc_bridge:
    fail("read-only MobileConfig bridge must never synthesize an app-owned data directory")
mc_json = read("src/Features/ExpFlags/RYGMobileConfigJSONIO.m")
require(mc_json, ('@"_qe_overrides_"', '@": : "', "RYGMCParseCanonicalJSONValue"), "canonical MobileConfig JSON")
require(mc_json, (
    "com.ryukgram.mobileconfig.runtime-snapshot.v1",
    "ryg_exportRuntimeSnapshotData",
    "ryg_importRuntimeSnapshotOverridesData",
    '@"import_policy": @"restore_explicit_overrides_only"',
), "portable typed MobileConfig snapshot")
if "external mapping entry that is absent from this binary's live table" not in mc:
    fail("MobileConfig browser must not fabricate rows/PIDs from id_name_mapping")
mc_browser = read("src/Features/ExpFlags/RYGFastMobileConfigBrowserViewController.m")
require(mc_browser, (
    '@"ABProps Runtime"',
    "Export current runtime configuration",
    "Import runtime snapshot / overrides",
    "ryg_importRuntimeSnapshotOverridesData",
), "ABProps runtime browser")
for legacy_mapping_action in ("Import id_name_mapping.json", "Export id_name_mapping.json", "RYGFastMCImportNames"):
    if legacy_mapping_action in mc_browser:
        fail(f"id_name_mapping UI returned as the ABProps browser authority: {legacy_mapping_action}")
mc_authority = read("src/Features/ExpFlags/RYGMobileConfigNativeAuthority.m")
require(mc_authority, (
    "FBMobileConfigFBTGlobalSessionManager",
    "currentSessionContextManagerHolder",
    "mcFbtManager",
    "ryg_resolveActiveSessionManager",
), "active MobileConfig manager authority")
mc_native_owner = read("src/Features/ExpFlags/RYGMobileConfigNativeFileOwner.m")
if "RYGMCNativeFileWriteAndVerify" in mc_native_owner:
    fail("legacy native MobileConfig JSON writer returned")
for forbidden in ("mc_overrides_canonical.json", "ryg_importAndApplyOverridesData", "ryg_nativeOverridesJSONPath"):
    if forbidden in mc_native_owner:
        fail(f"foreground MobileConfig replay must use only the typed local store: {forbidden}")
if re.search(r"ryg_nativeOverridesJSONPath[^\n]*\n?[^\n]*writeToFile", mc, re.S):
    fail("MobileConfig core writes Instagram's native mc_overrides.json")
if "Instagram's C++ mc_overrides.json is" not in mc:
    fail("MobileConfig core read-only native JSON contract missing")

# EasyGating must stay sideload-safe: import rebinding only, no signed __TEXT patch.
easy = read("src/Debug/RYGEasyGatingRuntime.m")
require(easy, ('name = "EasyGatingGetBoolean_Internal_DoNotUseOrMock"', "rebind_symbols_image", "RYGResolveFinalGateID", "RYGEasyGatingImageRangeHasProtection", "ryg_easy_gating_platform_bool_overrides_v2"), "EasyGating")
require(easy, ("RYGDecodeARM64DirectBranch", "RYGFindEasyGatingMapper", "RYGEasyGatingMapperInstructionsMatch"), "EasyGating structural mapper")
if "wrapperAddress + 0x34" in easy:
    fail("EasyGating mapper reverted to a build-specific wrapper offset")
if re.search(r'dlsym\s*\([^\n]*"EasyGatingPlatformGetBoolean"', easy):
    fail("EasyGating must not patch the signed FBShared platform function")

meta_local = read("src/Debug/RYGMetaLocalExperimentBrowser.m")
require(meta_local, (
    "FDIDExperimentGenerator",
    "generateConfigs",
    "OdinFamilyDeviceIDSignalProvider",
    "currentFamilyDeviceID",
    "initWithFamilyDeviceID:logger:",
), "Meta family-local experiments")

liquid = read("src/UI/RYGLiquidGlass.m")
if 'return ![RYGUtils getBoolPref:@"liquid_glass_force_off"]' not in liquid:
    fail("Liquid Glass availability/accessibility contract changed")
if "return !UIAccessibilityIsReduceTransparencyEnabled()" in liquid:
    fail("Liquid Glass must let UIKit adapt Reduce Transparency")

# Build surfaces may not drift back to older SDKs or helper dylibs.
build_surfaces = [ROOT / "Makefile", ROOT / "build.sh", ROOT / "build-fast.sh"]
build_surfaces.extend(sorted((ROOT / ".github/workflows").glob("*.yml")))
for path in build_surfaces:
    if not path.exists(): continue
    text = path.read_text(encoding="utf-8", errors="replace")
    if re.search(r"iPhoneOS(?:16\.2|26\.2)\.sdk|iphone:clang:(?:16\.2|26\.2)", text):
        fail(f"old SDK reference in {path.relative_to(ROOT)}")
    if re.search(r"ipapatch|--dylib\s+\S*(?:pluginsinject|noplugin|sideloadpatch)", text, re.I):
        fail(f"separate helper injection remains in {path.relative_to(ROOT)}")

# Generic source/Logos sanity.
active_sources: list[Path] = []
for suffix in ("*.m","*.mm","*.x","*.xm","*.h"):
    active_sources.extend((ROOT / "src").rglob(suffix))
legacy_symbol = re.compile(r"\bSCI[A-Z][A-Za-z0-9_]*|\bsci[A-Z][A-Za-z0-9_]*")
for path in active_sources:
    text = path.read_text(encoding="utf-8", errors="replace")
    code = re.sub(r"/\*.*?\*/|//[^\n]*", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    code = re.sub(r'@?"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', '""', code)
    bad = legacy_symbol.search(code)
    if bad: fail(f"unmigrated legacy symbol {bad.group(0)!r} in {path.relative_to(ROOT)}")
    if path.suffix in {".x", ".xm"}:
        if re.search(r"%orig\s*\(\s*\)", code): fail(f"no-argument %orig() in {path.relative_to(ROOT)}")
        for line_number, line in enumerate(code.splitlines(), 1):
            tail = logos_orig_tail(line)
            if tail is not None: fail(f"tokens follow %orig in {path.relative_to(ROOT)}:{line_number}: {tail.strip()!r}")

logos = Path(os.environ.get("THEOS", "")) / "bin/logos.pl" if os.environ.get("THEOS") else None
if logos and logos.is_file():
    for path in sorted(p for p in active_sources if p.suffix in {".x", ".xm"}):
        result = subprocess.run(["perl", str(logos), str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False)
        if result.returncode:
            detail = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else "unknown Logos error"
            fail(f"Logos preprocessing failed for {path.relative_to(ROOT)}: {detail}")

print("source validation OK: SDK 26.5, native Developer wiring intact, structural EasyGating mapper, typed runtime browser/store, runtime-backed MobileConfig rows, read-only native JSON, portable snapshots, active manager resolution, FDID local experiments")
