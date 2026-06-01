"""Profile JSON Schema validation against every shipped factory profile."""
import json
from pathlib import Path

import pytest

try:
    import jsonschema
except ImportError:
    pytest.skip("jsonschema not installed", allow_module_level=True)


REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA = REPO_ROOT / "control-plane" / "profile.schema.json"
FACTORY_DIR = REPO_ROOT / "control-plane" / "profiles" / "factory"


@pytest.fixture
def schema():
    return json.loads(SCHEMA.read_text())


@pytest.mark.parametrize("profile_path",
                          sorted(FACTORY_DIR.glob("*.json")),
                          ids=lambda p: p.stem)
def test_factory_profile_validates(schema, profile_path):
    profile = json.loads(profile_path.read_text())
    jsonschema.validate(instance=profile, schema=schema)


def test_schema_self_validates(schema):
    jsonschema.validators.Draft202012Validator.check_schema(schema)


def test_synthetic_profile_validates(schema):
    """A minimal hand-crafted profile passes."""
    p = {
        "schema": "schindler-profile",
        "schema_version": "0.1.0",
        "catalog_version": "0.2.0",
        "name": "test",
        "controls": {"color.saturation": 100},
    }
    jsonschema.validate(instance=p, schema=schema)


def test_unknown_field_rejected(schema):
    p = {
        "schema": "schindler-profile",
        "schema_version": "0.1.0",
        "catalog_version": "0.2.0",
        "name": "test",
        "controls": {"color.saturation": 100},
        "rogue_field": True,
    }
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=p, schema=schema)


def test_bad_control_id_pattern_rejected(schema):
    p = {
        "schema": "schindler-profile",
        "schema_version": "0.1.0",
        "catalog_version": "0.2.0",
        "name": "test",
        "controls": {"NotADotPath!": 100},
    }
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=p, schema=schema)


def test_invalid_name_rejected(schema):
    """Filesystem-unsafe name chars are rejected."""
    p = {
        "schema": "schindler-profile",
        "schema_version": "0.1.0",
        "catalog_version": "0.2.0",
        "name": "../etc/passwd",
        "controls": {},
    }
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=p, schema=schema)
