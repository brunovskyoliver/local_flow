#!/usr/bin/env python3
"""Feature 025: the installer script agrees with the Rust code it installs. Needs no ISCC."""
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
iss = (root / "packaging/windows/localflow.iss").read_text()
cargo = (root / "apps/desktop/Cargo.toml").read_text()
system = (root / "crates/flow-platform/src/win/system.rs").read_text()


def rust_const(name):
    return re.search(rf'const {name}: &str = r?"([^"]+)"', system).group(1)


def define(name):
    return re.search(rf'#define {name} "([^"]+)"', iss).group(1)


# A [[bin]] table would rename the exe away from the package name.
bin_name = re.search(r'^name = "([^"]+)"', cargo, re.M).group(1)
problems = []
if "[[bin]]" in cargo:
    problems.append("apps/desktop has a [[bin]] table; check the exe name by hand and update this check")
if define("ExeName") != f"{bin_name}.exe":
    problems.append(f'ExeName is {define("ExeName")}, the Cargo bin builds {bin_name}.exe')
if define("RunKey") != rust_const("RUN_KEY"):
    problems.append(f'RunKey is {define("RunKey")}, Rust uses {rust_const("RUN_KEY")}')
if define("RunValue") != rust_const("RUN_VALUE"):
    problems.append(f'RunValue is {define("RunValue")}, Rust uses {rust_const("RUN_VALUE")}')
# The installer's README and uninstall promise name this folder.
windows = (root / "crates/flow-platform/src/windows.rs").read_text()
if not re.search(r'fn data_folder\(&self\) -> &\'static str \{\s*"LocalFlow"\s*\}', windows):
    problems.append(r"Windows data must live in %LOCALAPPDATA%\LocalFlow, as the installer says")
if not re.search(r"^PrivilegesRequired=lowest$", iss, re.M):
    problems.append("the installer must set PrivilegesRequired=lowest")

# Feature 026: the worker and exactly the libraries it verifies before loading.
worker = re.search(r'^name = "([^"]+)"', (root / "crates/flow-speech-win/Cargo.toml").read_text(), re.M).group(1)
if define("WorkerName") != f"{worker}.exe":
    problems.append(f'WorkerName is {define("WorkerName")}, the Cargo bin builds {worker}.exe')
if not re.search(r'^Source: "[^"]*\\{#WorkerName}"; DestDir: "\{app\}"', iss, re.M):
    problems.append("the installer doesn't install the speech worker next to the exe")
manifest = json.loads((root / "crates/flow-speech-win/manifest.json").read_text())
wanted = {f["name"] for f in manifest["runtime"]["windows-x86_64"]["files"]}
listed = set(re.findall(r'^Source: "\{#SherpaDir\}\\([^"]+)"; DestDir: "\{app\}"', iss, re.M))
if wanted != listed:
    problems.append(f"the installer lists {sorted(listed)}, the worker's manifest pins {sorted(wanted)}")

for problem in problems:
    print(f"check-windows-installer: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
