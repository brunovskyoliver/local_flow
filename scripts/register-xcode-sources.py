#!/usr/bin/env python3
"""Register Swift source files in apps/macos/LocalFlow.xcodeproj/project.pbxproj.

Usage: scripts/register-xcode-sources.py LocalFlow/Core/Foo.swift LocalFlowTests/FooTests.swift

Paths are relative to apps/macos. Files under LocalFlowTests/ join the test target's
sources phase; every other file joins the app target's. Already-registered paths are
skipped. Identifiers are derived from a hash of the path so repeated runs are stable.
"""
import hashlib
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "apps/macos/LocalFlow.xcodeproj/project.pbxproj"
GROUP = "A00000000000000000000003"
APP_SOURCES = "A0000000000000000000000B"
TEST_SOURCES = "B00000000000000000000068"


def identifier(seed: str) -> str:
    return "F010" + hashlib.sha256(seed.encode()).hexdigest()[:20].upper()


def main(paths):
    text = PROJECT.read_text()
    added = []
    for path in paths:
        if f'"path" = "{path}"' in text:
            print(f"already registered: {path}")
            continue
        file_ref = identifier("ref:" + path)
        build = identifier("build:" + path)
        entry = (
            f'    "{file_ref}" = {{ "isa" = "PBXFileReference"; "path" = "{path}"; '
            f'"lastKnownFileType" = "sourcecode.swift"; "sourceTree" = "<group>"; }};\n'
            f'    "{build}" = {{ "isa" = "PBXBuildFile"; "fileRef" = "{file_ref}"; }};\n'
        )
        text = text.replace('  "objects" = {\n', '  "objects" = {\n' + entry, 1)
        text = append_to_list(text, GROUP, "children", file_ref)
        phase = TEST_SOURCES if path.startswith("LocalFlowTests/") else APP_SOURCES
        text = append_to_list(text, phase, "files", build)
        added.append(path)
    PROJECT.write_text(text)
    for path in added:
        print(f"registered: {path}")


def append_to_list(text: str, object_id: str, key: str, value: str) -> str:
    pattern = re.compile(
        r'("' + re.escape(object_id) + r'" = \{[^}]*?"' + key + r'" = \()([^)]*)(\))', re.S)
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"could not find {key} list of {object_id}")
    items = match.group(2).rstrip()
    joined = items + (", " if items.strip() else "") + f'"{value}"'
    return text[: match.start(2)] + joined + text[match.end(2):]


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    main(sys.argv[1:])
