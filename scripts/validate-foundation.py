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

# A JSON Schema subset validator, enough for protocol/schemas: $ref (local and
# sibling files), type, const, enum, required, properties, additionalProperties,
# items, min/maxItems, uniqueItems, min/maxLength, pattern, minimum, maximum,
# oneOf, anyOf, allOf, not and if/then/else. An unknown keyword is an error so a
# schema never silently validates less than it says.
schemas_dir = root / "protocol/schemas"
annotations = {"$schema", "$id", "$defs", "title", "description", "format", "examples", "default"}
json_types = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
}


def load_schema(name):
    return json.loads((schemas_dir / name).read_text())


def resolve(ref, document):
    file_part, _, pointer = ref.partition("#")
    if file_part:
        document = load_schema(file_part)
    node = document
    for part in filter(None, pointer.split("/")):
        node = node[part]
    return node, document


def errors(value, schema, document):
    """Returns a list of violations (empty when value matches)."""
    if schema is True:
        return []
    if schema is False:
        return ["false schema"]
    found = []
    for key, rule in schema.items():
        if key in annotations or key in ("then", "else"):
            continue
        if key == "$ref":
            target, target_document = resolve(rule, document)
            found += errors(value, target, target_document)
        elif key == "type":
            names = rule if isinstance(rule, list) else [rule]
            if not any(json_types[name](value) for name in names):
                found.append(f"type {rule}")
        elif key == "const":
            if type(value) is not type(rule) or value != rule:
                found.append(f"const {rule!r}")
        elif key == "enum":
            if not any(type(value) is type(item) and value == item for item in rule):
                found.append(f"enum {rule}")
        elif key == "required":
            if isinstance(value, dict):
                found += [f"missing {name}" for name in rule if name not in value]
        elif key == "properties":
            if isinstance(value, dict):
                for name, sub in rule.items():
                    if name in value:
                        found += [f"{name}: {e}" for e in errors(value[name], sub, document)]
        elif key == "additionalProperties":
            if isinstance(value, dict):
                extra = [name for name in value if name not in schema.get("properties", {})]
                for name in extra:
                    found += [f"{name}: {e}" for e in errors(value[name], rule, document)]
        elif key == "items":
            if isinstance(value, list):
                for index, item in enumerate(value):
                    found += [f"[{index}]: {e}" for e in errors(item, rule, document)]
        elif key in ("minItems", "maxItems", "minLength", "maxLength"):
            if isinstance(value, list if key.endswith("Items") else str):
                if (len(value) < rule) if key.startswith("min") else (len(value) > rule):
                    found.append(f"{key} {rule}")
        elif key == "uniqueItems":
            if rule and isinstance(value, list):
                encoded = [json.dumps(item, sort_keys=True) for item in value]
                if len(set(encoded)) != len(encoded):
                    found.append("uniqueItems")
        elif key == "pattern":
            if isinstance(value, str) and not re.search(rule, value):
                found.append(f"pattern {rule}")
        elif key in ("minimum", "maximum"):
            if json_types["number"](value) and ((value < rule) if key == "minimum" else (value > rule)):
                found.append(f"{key} {rule}")
        elif key == "oneOf":
            matches = sum(1 for sub in rule if not errors(value, sub, document))
            if matches != 1:
                found.append(f"oneOf matched {matches}")
        elif key == "anyOf":
            if all(errors(value, sub, document) for sub in rule):
                found.append("anyOf matched none")
        elif key == "allOf":
            for sub in rule:
                found += errors(value, sub, document)
        elif key == "not":
            if not errors(value, rule, document):
                found.append("not")
        elif key == "if":
            branch = "else" if errors(value, rule, document) else "then"
            if branch in schema:
                found += errors(value, schema[branch], document)
        else:
            raise AssertionError(f"unsupported schema keyword {key}")
    return found


# fixtures/remote/messages: valid/<name>.json must match and invalid/<name>.json
# must not. identity* files use remote-identity, hello* remote-hello, the rest
# remote-message.
def schema_for(name):
    for prefix in ("identity", "hello"):
        if name.startswith(prefix):
            return f"remote-{prefix}.schema.json"
    return "remote-message.schema.json"


messages = root / "fixtures/remote/messages"
checked = 0
for kind in ("valid", "invalid"):
    files = sorted((messages / kind).glob("*.json"))
    assert files, f"no {kind} remote message examples"
    for path in files:
        schema_name = schema_for(path.stem)
        schema = load_schema(schema_name)
        found = errors(json.loads(path.read_text()), schema, schema)
        if kind == "valid":
            assert not found, (path, found)
        else:
            assert found, (path, "unexpectedly valid")
        checked += 1
message_types = {ref["$ref"].rsplit("/", 1)[1] for ref in load_schema("remote-message.schema.json")["oneOf"]}
examples = {path.stem.split("-")[0] for path in (messages / "valid").glob("*.json")}
invalid_examples = {path.stem.split("-")[0] for path in (messages / "invalid").glob("*.json")}
assert message_types <= examples and message_types <= invalid_examples, message_types - (examples & invalid_examples)
print(f"JSON syntax, Spec Kit artifacts, documentation links and {checked} remote message examples validated")
