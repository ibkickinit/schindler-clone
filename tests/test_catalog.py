"""Catalog: schema load, type coercion, availability annotation."""
import json
from pathlib import Path

import pytest

from schindlerd import Catalog, CatalogControl


def test_catalog_loads_live_file(catalog_path):
    cat = Catalog.load(catalog_path)
    assert cat.version == "0.2.0"
    assert "color.saturation" in cat.controls
    assert "scaler.kernel_h" in cat.controls
    assert "status.s2mm_sr" in cat.controls


def test_enum_string_to_int_coercion(catalog_path):
    cat = Catalog.load(catalog_path)
    kh = cat.controls["scaler.kernel_h"]
    assert kh.coerce_to_firmware("nn") == 0
    assert kh.coerce_to_firmware("boxcar_2tap") == 1
    assert kh.coerce_to_firmware("boxcar_4tap") == 2


def test_enum_int_to_string_coercion(catalog_path):
    cat = Catalog.load(catalog_path)
    kh = cat.controls["scaler.kernel_h"]
    assert kh.coerce_from_firmware(0) == "nn"
    assert kh.coerce_from_firmware(1) == "boxcar_2tap"
    assert kh.coerce_from_firmware(2) == "boxcar_4tap"


def test_enum_unknown_string_raises(catalog_path):
    cat = Catalog.load(catalog_path)
    kh = cat.controls["scaler.kernel_h"]
    with pytest.raises(ValueError):
        kh.coerce_to_firmware("polyphase_64tap")


def test_number_coercion_passes_through(catalog_path):
    cat = Catalog.load(catalog_path)
    sat = cat.controls["color.saturation"]
    assert sat.coerce_to_firmware(150) == 150
    assert sat.coerce_from_firmware(150) == 150


def test_annotated_raw_marks_firmware_available(catalog_path):
    cat = Catalog.load(catalog_path)
    cat.available_ids = {"color.saturation", "scaler.kernel_h"}
    raw = cat.annotated_raw()
    by_id = {c["id"]: c for c in raw["controls"]}
    assert by_id["color.saturation"]["available"] is True
    assert by_id["scaler.kernel_h"]["available"] is True
    # Not in firmware list, not a status control → unavailable
    assert by_id["color.correct.black_r"]["available"] is False


def test_annotated_raw_status_always_available(catalog_path):
    cat = Catalog.load(catalog_path)
    cat.available_ids = set()  # firmware reports nothing
    raw = cat.annotated_raw()
    by_id = {c["id"]: c for c in raw["controls"]}
    # status.* entries are synthesized by the daemon — should be available
    # regardless of firmware list
    assert by_id["status.s2mm_sr"]["available"] is True
    assert by_id["status.source_lock"]["available"] is True


def test_annotated_raw_placeholder_forced_unavailable(catalog_path):
    cat = Catalog.load(catalog_path)
    cat.available_ids = {"frc.mackin_alpha"}  # even if "available" per firmware
    raw = cat.annotated_raw()
    by_id = {c["id"]: c for c in raw["controls"]}
    # mackin alpha has requires_status: placeholder → always unavailable
    assert by_id["frc.mackin_alpha"]["available"] is False


def test_custom_catalog_via_tmp_path(tmp_path):
    cat_file = tmp_path / "cat.json"
    cat_file.write_text(json.dumps({
        "schema_version": "0.1.0",
        "categories": [{"id": "test", "title": "Test"}],
        "controls": [
            {"id": "test.flag", "title": "Flag", "category": "test",
             "type": "boolean", "default": False, "surface": ["web"]}
        ]
    }))
    cat = Catalog.load(cat_file)
    assert cat.version == "0.1.0"
    flag = cat.controls["test.flag"]
    assert flag.coerce_to_firmware(True) == 1
    assert flag.coerce_to_firmware(False) == 0
    assert flag.coerce_from_firmware(1) is True
    assert flag.coerce_from_firmware(0) is False
