#!/usr/bin/env python3
"""Register Swift source files in apps/macos/LocalFlow.xcodeproj/project.pbxproj.

Usage: scripts/register-xcode-sources.py [--target app|tests|flowd-speech] LocalFlow/Core/Foo.swift ...

Paths are relative to apps/macos. Without --target, files under LocalFlowTests/ join the
test target's sources phase and every other file joins the app target's. With --target, every
listed file joins that target's sources phase; a file may belong to several targets and keeps
one file reference. Already-registered files are skipped per target. Identifiers are derived
from a hash of the path (and target, for non-default targets) so repeated runs are stable.
"""
import hashlib
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "apps/macos/LocalFlow.xcodeproj/project.pbxproj"
GROUP = "A00000000000000000000003"
PHASES = {
    "app": "A0000000000000000000000B",
    "tests": "B00000000000000000000068",
    # Created by scripts/add-speech-worker-target.py.
    "flowd-speech": "F0145000000000000000000B",
}


def identifier(seed: str) -> str:
    return "F010" + hashlib.sha256(seed.encode()).hexdigest()[:20].upper()


def default_target(path: str) -> str:
    return "tests" if path.startswith("LocalFlowTests/") else "app"


def main(argv):
    target = None
    if argv and argv[0] == "--target":
        if len(argv) < 3 or argv[1] not in PHASES:
            raise SystemExit(__doc__)
        target, argv = argv[1], argv[2:]
    if not argv:
        raise SystemExit(__doc__)
    text = PROJECT.read_text()
    added = []
    for path in argv:
        chosen = target or default_target(path)
        file_ref = identifier("ref:" + path)
        existing = re.search(r'"([0-9A-Z]{24})" = \{ "isa" = "PBXFileReference"; "path" = "'
                             + re.escape(path) + '"', text)
        if existing:
            file_ref = existing.group(1)
        elif f'"path" = "{path}"' in text:
            # A reference written in the multi-line style by an older tool.
            match = re.search(r'"([0-9A-Z]{24})" = \{\s*"path" = "' + re.escape(path) + '"', text)
            if not match:
                raise SystemExit(f"could not find the file reference of {path}")
            file_ref = match.group(1)
        else:
            entry = (
                f'    "{file_ref}" = {{ "isa" = "PBXFileReference"; "path" = "{path}"; '
                f'"lastKnownFileType" = "sourcecode.swift"; "sourceTree" = "<group>"; }};\n'
            )
            text = text.replace('  "objects" = {\n', '  "objects" = {\n' + entry, 1)
            text = append_to_list(text, GROUP, "children", file_ref)
        seed = "build:" + path if chosen == default_target(path) else f"build:{chosen}:{path}"
        build = identifier(seed)
        phase = PHASES[chosen]
        if phase_contains_file(text, phase, file_ref):
            print(f"already registered: {path} ({chosen})")
            continue
        entry = f'    "{build}" = {{ "isa" = "PBXBuildFile"; "fileRef" = "{file_ref}"; }};\n'
        text = text.replace('  "objects" = {\n', '  "objects" = {\n' + entry, 1)
        text = append_to_list(text, phase, "files", build)
        added.append(f"{path} ({chosen})")
    PROJECT.write_text(text)
    for path in added:
        print(f"registered: {path}")


def phase_contains_file(text: str, phase: str, file_ref: str) -> bool:
    match = re.search(r'"' + re.escape(phase) + r'" = \{[^}]*?"files" = \(([^)]*)\)', text, re.S)
    if not match:
        raise SystemExit(f"could not find the sources phase {phase}")
    builds = set(re.findall(r'"([0-9A-Z]{24})" = \{[^}]*?"fileRef" = "' + file_ref + '"', text))
    return any(build in builds for build in re.findall(r'"([0-9A-Z]{24})"', match.group(1)))


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
    main(sys.argv[1:])
