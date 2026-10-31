#!/usr/bin/env python3
"""Feature 024: every inventory row has a status and evidence that actually exists.

status/<NN>.tsv rows: ID <tab> status <tab> evidence. Statuses:
  auto      test:<rust_test_fn>  a test whose `// parity:` comment lists this ID
  live      live:<path>          a recorded run under ~/agent-runs/2026-10-31-gpui-views/
  service   service:<what is missing and which feature adds it>
  not-run   not-run:<why; owner or hardware only>
  recorded  recorded:<why this row has nothing to verify, such as a swift-note>
Several evidence items can be joined with ` ; `. `--allow-open` reports progress without failing.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INV = ROOT / "specs/024-gpui-desktop-views/inventory"
RUNS = Path.home() / "agent-runs/2026-10-31-gpui-views"
ROW = re.compile(r"^\| ([A-Z]+-\d+) \|\s*([a-z-]+)", re.M)
STATUSES = {"auto", "live", "service", "not-run", "recorded"}

rows = {}
for md in sorted(INV.glob("*.md")):
    for rid, kind in ROW.findall(md.read_text()):
        assert rid not in rows, f"duplicate row {rid}"
        rows[rid] = kind

# `// parity: A-1 A-2 A-5..A-9` directly above a test (attributes and other comments may intervene).
tags = {}
for src in list((ROOT / "crates").rglob("*.rs")) + list((ROOT / "apps/desktop").rglob("*.rs")):
    if "/build/" in str(src):
        continue
    pending = set()
    for line in src.read_text().splitlines():
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
            pending = set()

errors, seen, counts = [], {}, {}
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
        for item in items:
            if item.startswith("test:"):
                name = item[5:]
                if name not in tags:
                    errors.append(f"{rid}: no test {name} with a parity tag")
                elif rid not in tags[name]:
                    errors.append(f"{rid}: test {name} doesn't list it in its parity tag")
            elif item.startswith("live:") and RUNS.exists() and not (RUNS / item[5:]).exists():
                errors.append(f"{rid}: missing {item}")

open_rows = sorted(set(rows) - set(seen))
print(f"{len(rows)} rows: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + f", open {len(open_rows)}")
if errors:
    print("\n".join(errors[:60]), file=sys.stderr)
    print(f"{len(errors)} errors", file=sys.stderr)
    sys.exit(1)
if open_rows and "--allow-open" not in sys.argv:
    print("open rows, first 40: " + " ".join(open_rows[:40]), file=sys.stderr)
    sys.exit(1)
