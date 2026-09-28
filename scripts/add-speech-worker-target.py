#!/usr/bin/env python3
"""Add the `flowd-speech` command-line target to apps/macos/LocalFlow.xcodeproj (Feature 014).

Usage: scripts/add-speech-worker-target.py

Idempotent: a project that already has the target is left unchanged. The target builds the
speech worker flowd starts as a child process (contracts/speech-worker-ipc.md). It links
FluidAudio through the project's existing package reference and has an empty sources phase;
add files with `scripts/register-xcode-sources.py --target flowd-speech <paths>`.
"""
import re
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "apps/macos/LocalFlow.xcodeproj/project.pbxproj"
TARGET = "F01450000000000000000001"
PRODUCT = "F01450000000000000000002"
CONFIG_LIST = "F01450000000000000000003"
DEBUG = "F01450000000000000000004"
RELEASE = "F01450000000000000000005"
SOURCES = "F0145000000000000000000B"
FRAMEWORKS = "F0145000000000000000000C"
FLUID_PRODUCT = "F0145000000000000000000D"
FLUID_BUILD = "F0145000000000000000000E"
FLUID_PACKAGE = "C00000000000000000000001"
PROJECT_OBJECT = "A00000000000000000000001"
PRODUCTS_GROUP = "A00000000000000000000004"


def settings(debug: bool) -> str:
    conditions = "DEBUG SPEECH_WORKER" if debug else "SPEECH_WORKER"
    optimization = "-Onone" if debug else "-O"
    return (
        '{ "PRODUCT_NAME" = "flowd-speech"; "SWIFT_VERSION" = "6.0"; '
        '"MACOSX_DEPLOYMENT_TARGET" = "14.0"; "CODE_SIGN_STYLE" = "Automatic"; '
        '"ENABLE_HARDENED_RUNTIME" = "YES"; "SKIP_INSTALL" = "YES"; '
        f'"SWIFT_ACTIVE_COMPILATION_CONDITIONS" = "{conditions}"; '
        f'"SWIFT_OPTIMIZATION_LEVEL" = "{optimization}"; "DEAD_CODE_STRIPPING" = "YES"; }}'
    )


def append_to_list(text: str, object_id: str, key: str, value: str) -> str:
    pattern = re.compile(
        r'("' + re.escape(object_id) + r'" = \{[^}]*?"' + key + r'" = \()([^)]*)(\))', re.S)
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"could not find {key} list of {object_id}")
    items = match.group(2).rstrip()
    joined = items + (", " if items.strip() else "") + f'"{value}"'
    return text[: match.start(2)] + joined + text[match.end(2):]


def main():
    text = PROJECT.read_text()
    if f'"{TARGET}"' in text:
        print("flowd-speech target already present")
        return
    objects = "".join(
        f"    {line}\n"
        for line in [
            f'"{PRODUCT}" = {{ "isa" = "PBXFileReference"; "path" = "flowd-speech"; '
            '"explicitFileType" = "compiled.mach-o.executable"; "includeInIndex" = "0"; '
            '"sourceTree" = "BUILT_PRODUCTS_DIR"; };',
            f'"{SOURCES}" = {{ "isa" = "PBXSourcesBuildPhase"; "buildActionMask" = "2147483647"; '
            '"files" = (); "runOnlyForDeploymentPostprocessing" = "0"; };',
            f'"{FLUID_PRODUCT}" = {{ "isa" = "XCSwiftPackageProductDependency"; '
            f'"package" = "{FLUID_PACKAGE}"; "productName" = "FluidAudio"; }};',
            f'"{FLUID_BUILD}" = {{ "isa" = "PBXBuildFile"; "productRef" = "{FLUID_PRODUCT}"; }};',
            f'"{FRAMEWORKS}" = {{ "isa" = "PBXFrameworksBuildPhase"; "buildActionMask" = "2147483647"; '
            f'"files" = ("{FLUID_BUILD}"); "runOnlyForDeploymentPostprocessing" = "0"; }};',
            f'"{DEBUG}" = {{ "isa" = "XCBuildConfiguration"; "name" = "Debug"; '
            f'"buildSettings" = {settings(True)}; }};',
            f'"{RELEASE}" = {{ "isa" = "XCBuildConfiguration"; "name" = "Release"; '
            f'"buildSettings" = {settings(False)}; }};',
            f'"{CONFIG_LIST}" = {{ "isa" = "XCConfigurationList"; '
            f'"buildConfigurations" = ("{DEBUG}", "{RELEASE}"); '
            '"defaultConfigurationIsVisible" = "0"; "defaultConfigurationName" = "Release"; };',
            f'"{TARGET}" = {{ "isa" = "PBXNativeTarget"; "name" = "flowd-speech"; '
            '"productName" = "flowd-speech"; "productType" = "com.apple.product-type.tool"; '
            f'"productReference" = "{PRODUCT}"; "buildConfigurationList" = "{CONFIG_LIST}"; '
            f'"buildPhases" = ("{SOURCES}", "{FRAMEWORKS}"); "buildRules" = (); '
            f'"dependencies" = (); "packageProductDependencies" = ("{FLUID_PRODUCT}"); }};',
        ]
    )
    text = text.replace('  "objects" = {\n', '  "objects" = {\n' + objects, 1)
    text = append_to_list(text, PROJECT_OBJECT, "targets", TARGET)
    text = append_to_list(text, PRODUCTS_GROUP, "children", PRODUCT)
    PROJECT.write_text(text)
    print("added flowd-speech target")


if __name__ == "__main__":
    main()
