"""Catalog JSON Schema validation.

Enforces the catalog format contract documented in
docs/wiki/CATALOG-EVOLUTION.md. The schema is the formal sibling of that
prose; this test ensures the shipped catalog conforms.
"""
import json
from pathlib import Path

import pytest

try:
    import jsonschema
except ImportError:
    pytest.skip("jsonschema not installed", allow_module_level=True)


REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA = REPO_ROOT / "control-plane" / "catalog.schema.json"
CATALOG = REPO_ROOT / "control-plane" / "catalog-v0.2.0.json"


@pytest.fixture
def schema():
    return json.loads(SCHEMA.read_text())


@pytest.fixture
def catalog():
    return json.loads(CATALOG.read_text())


def test_shipped_catalog_validates(schema, catalog):
    jsonschema.validate(instance=catalog, schema=schema)


def test_schema_self_validates(schema):
    """The schema itself must be a valid JSON Schema 2020-12 document."""
    cls = jsonschema.validators.Draft202012Validator
    cls.check_schema(schema)


def test_every_enum_control_has_options(schema, catalog):
    """The 'enum requires options' branch in allOf must actually fire."""
    enum_controls = [c for c in catalog["controls"] if c.get("type") == "enum"]
    for c in enum_controls:
        assert "options" in c, f"{c['id']} declared enum but has no options"
        assert len(c["options"]) > 0, f"{c['id']} has empty options array"


def test_every_control_category_exists(schema, catalog):
    cat_ids = {cat["id"] for cat in catalog["categories"]}
    for c in catalog["controls"]:
        assert c["category"] in cat_ids, (
            f"{c['id']} references unknown category '{c['category']}'")


def test_every_control_id_starts_with_its_category(catalog):
    """Soft naming convention enforcement: id prefix matches category."""
    for c in catalog["controls"]:
        head = c["id"].split(".")[0]
        # Allow "system" controls to live under any category, since system.* is
        # cross-cutting meta. Otherwise: id must begin with its category id.
        if head == "system":
            continue
        assert head == c["category"], (
            f"control {c['id']} has category={c['category']} but id starts "
            f"with '{head}' — convention violation")


def test_no_duplicate_control_ids(catalog):
    ids = [c["id"] for c in catalog["controls"]]
    assert len(ids) == len(set(ids)), "duplicate control ids in catalog"


def test_missing_required_field_rejected(schema, catalog):
    """Schema must reject a control missing 'type'."""
    bad = json.loads(json.dumps(catalog))
    del bad["controls"][0]["type"]
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=bad, schema=schema)


def test_unknown_top_level_field_rejected(schema, catalog):
    """additionalProperties: false should reject garbage."""
    bad = json.loads(json.dumps(catalog))
    bad["unknown_thing"] = 42
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=bad, schema=schema)


def test_invalid_id_pattern_rejected(schema, catalog):
    """Uppercase + special chars in id are rejected."""
    bad = json.loads(json.dumps(catalog))
    bad["controls"][0]["id"] = "Color.Saturation!"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=bad, schema=schema)
