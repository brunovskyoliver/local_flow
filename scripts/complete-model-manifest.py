#!/usr/bin/env python3
"""Verify already-downloaded pinned assets and complete their SHA-256 manifest.

This developer tool never downloads files. Rebuild the app after it succeeds.
"""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("model_directory", type=Path)
parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[1] / "apps/macos/LocalFlow/Resources/Models/parakeet-v3.json")
args = parser.parse_args()
manifest = json.loads(args.manifest.read_text())
root = args.model_directory.absolute()
if root.is_symlink() or not root.is_dir():
    parser.error("The model directory must be a real directory.")
for item in manifest["files"]:
    source = root
    for component in Path(item["path"]).parts:
        if component in ("..", ".", "/"):
            parser.error("Invalid manifest path")
        source = source / component
        if source.is_symlink():
            parser.error(f"Symlink rejected: {item['path']}")
    if not source.is_file() or source.stat().st_size != item["size"]:
        parser.error(f"Wrong or missing pinned file: {item['path']}")
    sha256 = hashlib.sha256()
    git_blob = hashlib.sha1(f"blob {item['size']}\0".encode())
    count = 0
    with source.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            count += len(chunk)
            if count > item["size"]:
                parser.error(f"File changed while reading: {item['path']}")
            sha256.update(chunk)
            git_blob.update(chunk)
    if count != item["size"]:
        parser.error(f"Short file: {item['path']}")
    expected = item["sha256"]
    if expected and sha256.hexdigest() != expected:
        parser.error(f"SHA-256 mismatch: {item['path']}")
    if not expected and git_blob.hexdigest() != item.get("sourceGitBlobSHA1"):
        parser.error(f"Pinned Git object mismatch: {item['path']}")
    item["sha256"] = sha256.hexdigest()
manifest["complete"] = True
# Only publish after every file passes verification.
temporary = args.manifest.with_suffix(".json.tmp")
temporary.write_text(json.dumps(manifest, indent=2) + "\n")
temporary.replace(args.manifest)
print(f"Verified {len(manifest['files'])} pinned files; completed {args.manifest}. Rebuild before importing.")
