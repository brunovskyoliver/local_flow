#!/usr/bin/env python3
"""Feature 025: the installer script agrees with the Rust code it installs. Needs no ISCC."""
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
if not re.search(r"^PrivilegesRequired=lowest$", iss, re.M):
    problems.append("the installer must set PrivilegesRequired=lowest")

for problem in problems:
    print(f"check-windows-installer: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
