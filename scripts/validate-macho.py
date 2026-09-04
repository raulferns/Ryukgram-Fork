#!/usr/bin/env python3
"""Validate and inspect a built RyukGram Mach-O using LIEF + Capstone.

This validator follows the runtime architecture actually compiled into dogfood.
It intentionally does not require legacy FBMobileConfigManager/OverridesTable C++
override entry points: the current implementation uses Instagram's native
FBMobileConfigStartupConfigs Objective-C override API after resolving the live
parameter table.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import capstone
import lief


FORBIDDEN = (
    b"zxPluginsInject.dylib",
    b"pluginsinject.dylib",
    b"NoPluginsPatch.dylib",
    b"SideloadPatch.dylib",
)

# Markers that must survive class obfuscation/stripping because the runtime uses
# them dynamically (dlsym / NSClassFromString / NSSelectorFromString) or because
# they are canonical file-format contracts.
REQUIRED = (
    b"RyukGramSideloadCompatibility",
    b"containerURLForSecurityApplicationGroupIdentifier:",
    b"UIGlassEffect",
    # EasyGating is hooked at the internal wrapper after selector/index ->
    # final gate-ID mapping.  Requiring the platform getter here would accept
    # a dylib that carries only a stale diagnostic string and never installs
    # the wrapper hook used by RYGEasyGatingRuntime.
    b"EasyGatingGetBoolean_Internal_DoNotUseOrMock",
    b"ryg_easy_gating_platform_bool_overrides_v2",
    # The legacy mapping may still decorate names, but the browser/persistence
    # contract is the typed runtime snapshot and exact local value store.
    b"com.ryukgram.mobileconfig.runtime-snapshot.v1",
    b"ryg_runtime_typed_value_overrides_v1",
    # Canonical MobileConfig read-only/import-export format.
    b"mc_overrides.json",
    b"_qe_overrides_",
    b": : ",
    # Live MobileConfig metadata contracts validated against current FBShared.
    b"_ZN12mobileconfig17typeFromParameterEy",
    b"_ZN12mobileconfig23kMobileConfigParamsListE",
    b"_ZN12mobileconfig23kMobileConfigParamsSizeE",
    # Native, typed MobileConfig override owner/API.  These replace the old
    # handcrafted std::shared_ptr/C++ OverridesTable call path.
    b"FBMobileConfigStartupConfigs",
    b"getInstance",
    b"setOverrideForParam:andValue:",
    b"removeOverrideForParam:",
    # Current-session manager wiring used for effective reads and native paths.
    b"FBMobileConfigFBTGlobalSessionManager",
    b"currentSessionContextManagerHolder",
    b"mcFbtManager",
    b"mobileconfig",
)

# The rebuild deliberately removed these fragile direct C++ override paths.
# Seeing them in RyukGram again would indicate a regression back to the old ABI
# assumptions rather than use of StartupConfigs' native typed dispatcher.
LEGACY_MOBILECONFIG_OVERRIDE_MARKERS = (
    b"_ZN12mobileconfig21FBMobileConfigManager25getOrCreateOverridesTableEb",
    b"_ZN12mobileconfig28FBMobileConfigOverridesTable22updateOverrideForParamEybb",
    b"_ZN12mobileconfig28FBMobileConfigOverridesTable22updateOverrideForParamEyxb",
    b"_ZN12mobileconfig28FBMobileConfigOverridesTable22updateOverrideForParamEydb",
    b"_ZN12mobileconfig28FBMobileConfigOverridesTable22updateOverrideForParamEyRKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEb",
    b"_ZN12mobileconfig28FBMobileConfigOverridesTable22removeOverrideForParamEyb",
)


def die(message: str) -> None:
    print(f"Mach-O validation error: {message}", file=sys.stderr)
    raise SystemExit(1)


def choose_binary(parsed: object):
    if parsed is None:
        return None
    if isinstance(parsed, lief.MachO.Binary):
        return parsed
    try:
        candidates = list(parsed)
    except TypeError:
        return None
    for candidate in candidates:
        cpu = str(candidate.header.cpu_type).upper()
        if "ARM64" in cpu:
            return candidate
    return candidates[0] if candidates else None


def library_names(binary) -> list[str]:
    return [str(getattr(library, "name", library)) for library in getattr(binary, "libraries", [])]


def disassemble_text(binary) -> tuple[int, list[str]]:
    section = binary.get_section("__text")
    if section is None:
        return 0, []
    content = bytes(section.content[:128])
    if not content:
        return 0, []
    address = int(getattr(section, "virtual_address", 0))
    engine = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    instructions = []
    for insn in engine.disasm(content, address):
        instructions.append(f"0x{insn.address:x}: {insn.mnemonic} {insn.op_str}".rstrip())
        if len(instructions) >= 8:
            break
    return len(content), instructions


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("macho", type=Path)
    args = parser.parse_args()
    path = args.macho.resolve()
    if not path.is_file():
        die(f"file not found: {path}")

    raw = path.read_bytes()
    lower_raw = raw.lower()
    for marker in FORBIDDEN:
        if marker.lower() in lower_raw:
            die(f"external helper marker remains: {marker.decode(errors='replace')}")

    missing = [marker.decode(errors="replace") for marker in REQUIRED if marker not in raw]
    if missing:
        die("required integrated marker(s) missing: " + ", ".join(missing))

    legacy = [
        marker.decode(errors="replace")
        for marker in LEGACY_MOBILECONFIG_OVERRIDE_MARKERS
        if marker in raw
    ]
    if legacy:
        die("legacy direct MobileConfig override ABI returned: " + ", ".join(legacy))

    try:
        parsed = lief.MachO.parse(str(path))
    except Exception as exc:
        die(f"LIEF could not parse {path.name}: {exc}")
    binary = choose_binary(parsed)
    if binary is None:
        die("LIEF returned no Mach-O slice")

    cpu = str(binary.header.cpu_type)
    if "ARM64" not in cpu.upper():
        die(f"unexpected CPU type: {cpu}")
    file_type = str(binary.header.file_type)
    if "DYLIB" not in file_type.upper():
        die(f"expected a dylib, got {file_type}")

    libraries = library_names(binary)
    forbidden_dependencies = [
        name for name in libraries
        if any(token.decode().lower() in name.lower() for token in FORBIDDEN)
    ]
    if forbidden_dependencies:
        die("forbidden dependency: " + ", ".join(forbidden_dependencies))

    byte_count, instructions = disassemble_text(binary)
    if byte_count and not instructions:
        die("Capstone could not decode the arm64 __text section")

    print(f"LIEF: {path.name} · {cpu} · {file_type} · {len(libraries)} dylib dependencies")
    print("Dependencies:")
    for name in libraries:
        print(f"  {name}")
    print(f"Capstone: decoded {len(instructions)} instruction(s) from {byte_count} __text bytes")
    for line in instructions:
        print(f"  {line}")
    print(
        "Integrated markers: sideload compatibility, App Group routing, "
        "UIGlassEffect, final-ID EasyGating wrapper ABI, typed runtime snapshots, "
        "live MobileConfig metadata, current-session manager wiring, native "
        "FBMobileConfigStartupConfigs typed override API"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
