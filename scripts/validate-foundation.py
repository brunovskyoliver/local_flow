"""Validate repository JSON, required artifacts and local Markdown links (stdlib only)."""
import json
import os
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for base in ("protocol", ".specify"):
    for path in (root / base).rglob("*.json"):
        json.loads(path.read_text())
pointer = root / ".specify/feature.json"
feature = os.environ.get("SPECIFY_FEATURE_DIRECTORY") or (
    json.loads(pointer.read_text())["feature_directory"]
    if pointer.exists() else "specs/001-local-dictation"
)
for name in ("spec.md", "plan.md", "research.md", "data-model.md", "quickstart.md"):
    assert (root / feature / name).is_file(), name
for skill in ("constitution", "specify", "clarify", "plan", "tasks", "analyze", "implement", "converge"):
    assert (root / f".agents/skills/speckit-{skill}/SKILL.md").is_file(), skill
for base in (root / "docs", root / "specs"):
    for path in base.rglob("*.md"):
        for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", path.read_text()):
            if "://" not in target and not target.startswith("#"):
                assert (path.parent / target.split("#")[0]).exists(), (path, target)
print("JSON syntax, Spec Kit artifacts and documentation links validated")
