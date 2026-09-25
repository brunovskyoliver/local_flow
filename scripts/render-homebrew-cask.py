#!/usr/bin/env python3
"""Render a cask only after a real release archive exists."""
import hashlib
from pathlib import Path
import re
import sys

version, archive, destination = sys.argv[1:]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("Version must be X.Y.Z")
sha256 = hashlib.sha256()
with Path(archive).open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        sha256.update(chunk)
template = Path(__file__).resolve().parent.parent / "packaging/homebrew/localflow.rb.in"
Path(destination).write_text(
    template.read_text().replace("@VERSION@", version).replace("@SHA256@", sha256.hexdigest())
)
