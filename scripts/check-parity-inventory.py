#!/usr/bin/env python3
"""Feature 024: every inventory row has a status and evidence that actually exists.

status/<NN>.tsv rows: ID <tab> status <tab> evidence. Statuses:
  auto      test:<rust_test_fn>  a test whose `// parity:` comment lists this ID
  live      live:<path>          a recorded run under ~/agent-runs/2026-10-31-gpui-views/
  service   service:<what is missing and which feature adds it>
  not-run   not-run:<why; owner or hardware only>
  recorded  recorded:<why this row has nothing to verify, such as a swift-note>
Several evidence items can be joined with ` ; `. `--allow-open` reports progress without failing.

Evidence must be able to fail. A test may tag no more rows than it has assertions. An `auto` row whose
reference gives a geometry value must cite a test that reads bounds. A `live` row citing `-rust.png` must
cite the `-ref.png` beside it, or say `rust-only:<why the reference can't reach it>`. `service` is only
for rows the inventory's Needs column gives to a platform service, a worker or flowd. Two different
states citing byte-identical `-rust.png` files are an error, since one of them shows the wrong state,
unless both are named together in SAME_IMAGE_ALLOWED.
"""
import hashlib
import itertools
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INV = ROOT / "specs/024-gpui-desktop-views/inventory"
RUNS = Path.home() / "agent-runs/2026-10-31-gpui-views"
ROW = re.compile(r"^\| ([A-Z]+-\d+) \|\s*([a-z-]+)\s*\|(.*)$", re.M)
GEOMETRY = re.compile(r"\b\d+(\.\d+)? (wide|high|tall)\b|\b(padding|spacing|radius|width|height|inset)\b", re.I)
ASSERTION = re.compile(r"\bassert\w*!?\(")
STATUSES = {"auto", "live", "service", "not-run", "recorded"}
# Pairs of evidence paths that really do look the same, each with its reason. Empty: none needed yet.
SAME_IMAGE_ALLOWED = {}

rows, details = {}, {}
for md in sorted(INV.glob("*.md")):
    for rid, kind, rest in ROW.findall(md.read_text()):
        assert rid not in rows, f"duplicate row {rid}"
        rows[rid] = kind
        details[rid] = rest

# `// parity: A-1 A-2 A-5..A-9` directly above a test (attributes and other comments may intervene).
tags, bodies = {}, {}


def body_of(lines, start):
    depth, out, opened = 0, [], False
    for line in lines[start:]:
        out.append(line)
        depth += line.count("{") - line.count("}")
        opened = opened or "{" in line
        if opened and depth <= 0:
            break
    return "\n".join(out)


def assertions(body):
    """Assertion macros, plus each item of `assert_saw(&[...])`, which asserts them one by one."""
    count = len(ASSERTION.findall(body))
    for items in re.findall(r"assert_saw\(&\[(.*?)\]\)", body, re.S):
        count += max(items.count('"') // 2 - 1, 0)
    return count


for src in list((ROOT / "crates").rglob("*.rs")) + list((ROOT / "apps/desktop").rglob("*.rs")):
    if "/build/" in str(src):
        continue
    pending = set()
    lines = src.read_text().splitlines()
    for number, line in enumerate(lines):
        m = re.search(r"//\s*parity:\s*(.*)", line)
        if m:
            for token in m.group(1).split():
                r = re.fullmatch(r"([A-Z]+)-(\d+)\.\.[A-Z]+-(\d+)", token)
                if r:
                    width = len(r.group(2))
                    pending |= {f"{r.group(1)}-{n:0{width}d}" for n in range(int(r.group(2)), int(r.group(3)) + 1)}
                elif re.fullmatch(r"[A-Z]+-\d+", token):
                    pending.add(token)
            continue
        f = re.search(r"\bfn (\w+)", line)
        if f:
            if pending:
                tags.setdefault(f.group(1), set()).update(pending)
                bodies[f.group(1)] = body_of(lines, number)
            pending = set()

errors, seen, counts, rust_images = [], {}, {}, {}
for tsv in sorted((INV / "status").glob("*.tsv")) if (INV / "status").exists() else []:
    for n, line in enumerate(tsv.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            errors.append(f"{tsv.name}:{n}: need 3 tab-separated fields")
            continue
        rid, status, evidence = parts
        if rid not in rows:
            errors.append(f"{tsv.name}:{n}: unknown row {rid}")
        if rid in seen:
            errors.append(f"{tsv.name}:{n}: {rid} listed twice")
        seen[rid] = status
        counts[status] = counts.get(status, 0) + 1
        if status not in STATUSES:
            errors.append(f"{rid}: bad status {status}")
            continue
        items = [e.strip() for e in evidence.split(" ; ") if e.strip()]
        if not items:
            errors.append(f"{rid}: no evidence")
        if status not in {"auto", "live"} and not any(i.startswith(status + ":") and len(i) > len(status) + 5 for i in items):
            errors.append(f"{rid}: {status} needs a reason")
        if status == "auto" and not any(i.startswith("test:") for i in items):
            errors.append(f"{rid}: auto needs test:")
        if status == "live" and not any(i.startswith("live:") for i in items):
            errors.append(f"{rid}: live needs live:")
        if status == "service" and not re.search(r"mac-service|worker|flowd", details.get(rid, "").rsplit("|", 2)[-2] if details.get(rid, "").count("|") >= 2 else ""):
            errors.append(f"{rid}: service, but the Needs column gives it to the app")
        if status == "auto" and rows.get(rid) in {"token", "view"} and GEOMETRY.search(details.get(rid, "")):
            if not any(i.startswith("test:") and re.search(r"bounds|assert_geometry", bodies.get(i[5:], "")) for i in items):
                errors.append(f"{rid}: geometry row, but no cited test reads bounds")
        if status == "live" and not any(i.startswith("rust-only:") for i in items):
            for item in items:
                if item.endswith("-rust.png") and item.replace("-rust.png", "-ref.png") not in items:
                    errors.append(f"{rid}: {item} without its -ref.png or rust-only: reason")
        for item in items:
            if item.startswith("test:"):
                name = item[5:]
                if name not in tags:
                    errors.append(f"{rid}: no test {name} with a parity tag")
                elif rid not in tags[name]:
                    errors.append(f"{rid}: test {name} doesn't list it in its parity tag")
            elif item.startswith("live:") and RUNS.exists():
                if not (RUNS / item[5:]).exists():
                    errors.append(f"{rid}: missing {item}")
                elif item.endswith("-rust.png"):
                    rust_images.setdefault(hashlib.sha256((RUNS / item[5:]).read_bytes()).digest(), set()).add(item[5:])

for name, tagged in tags.items():
    cited = {rid for rid in tagged if seen.get(rid) == "auto"}
    if len(cited) > assertions(bodies[name]):
        errors.append(f"test {name}: credits {len(cited)} rows with {assertions(bodies[name])} assertions")

for paths in rust_images.values():
    for a, b in itertools.combinations(sorted(paths), 2):
        if frozenset((a, b)) not in SAME_IMAGE_ALLOWED:
            errors.append(f"{a} and {b} are byte-identical: one shows the wrong state, or name them in SAME_IMAGE_ALLOWED")

open_rows = sorted(set(rows) - set(seen))
print(f"{len(rows)} rows: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + f", open {len(open_rows)}")
if errors:
    print("\n".join(errors if "--all" in sys.argv else errors[:60]), file=sys.stderr)
    print(f"{len(errors)} errors", file=sys.stderr)
    sys.exit(1)
if open_rows and "--allow-open" not in sys.argv:
    print("open rows, first 40: " + " ".join(open_rows[:40]), file=sys.stderr)
    sys.exit(1)
