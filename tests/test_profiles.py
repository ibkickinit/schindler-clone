"""ProfileStore: multi-root, user-shadows-factory, save-only-to-user."""
import json
from pathlib import Path

import pytest

from schindlerd import ProfileStore


@pytest.fixture
def user_root(tmp_path) -> Path:
    p = tmp_path / "user"
    p.mkdir()
    return p


@pytest.fixture
def factory_root(tmp_path) -> Path:
    p = tmp_path / "factory"
    p.mkdir()
    (p / "identity.json").write_text(json.dumps(
        {"name": "identity", "controls": {"color.saturation": 100}}
    ))
    (p / "warm.json").write_text(json.dumps(
        {"name": "warm", "controls": {"color.saturation": 110}}
    ))
    return p


def test_list_combines_user_and_factory(user_root, factory_root):
    (user_root / "mine.json").write_text(json.dumps(
        {"name": "mine", "controls": {"color.saturation": 130}}))
    store = ProfileStore(user_root, readonly_roots=[factory_root])
    names = {item["name"] for item in store.list()}
    assert names == {"mine", "identity", "warm"}


def test_list_marks_factory_flag(user_root, factory_root):
    store = ProfileStore(user_root, readonly_roots=[factory_root])
    items = {item["name"]: item for item in store.list()}
    assert items["identity"]["factory"] is True
    assert items["warm"]["factory"] is True


def test_user_profile_shadows_factory_in_list(user_root, factory_root):
    (user_root / "identity.json").write_text(json.dumps(
        {"name": "identity", "controls": {"color.saturation": 99}}))
    store = ProfileStore(user_root, readonly_roots=[factory_root])
    items = {item["name"]: item for item in store.list()}
    assert items["identity"]["factory"] is False


def test_load_user_shadows_factory(user_root, factory_root):
    (user_root / "identity.json").write_text(json.dumps(
        {"name": "identity", "controls": {"color.saturation": 99}}))
    store = ProfileStore(user_root, readonly_roots=[factory_root])
    prof = store.load("identity")
    assert prof["controls"]["color.saturation"] == 99


def test_load_falls_back_to_factory(user_root, factory_root):
    store = ProfileStore(user_root, readonly_roots=[factory_root])
    prof = store.load("warm")
    assert prof["controls"]["color.saturation"] == 110


def test_save_writes_to_user_dir(user_root, factory_root):
    store = ProfileStore(user_root, readonly_roots=[factory_root])
    store.save("mine", {"name": "mine", "controls": {"color.saturation": 175}})
    assert (user_root / "mine.json").is_file()
    assert not (factory_root / "mine.json").exists()


def test_save_overrides_factory_via_user_dir(user_root, factory_root):
    store = ProfileStore(user_root, readonly_roots=[factory_root])
    # Save same name as a factory profile; factory dir untouched.
    store.save("identity", {"name": "identity", "controls": {"color.saturation": 50}})
    assert (user_root / "identity.json").is_file()
    # Factory untouched.
    factory_text = (factory_root / "identity.json").read_text()
    assert "100" in factory_text  # original factory value


def test_load_missing_raises(user_root, factory_root):
    store = ProfileStore(user_root, readonly_roots=[factory_root])
    with pytest.raises(FileNotFoundError):
        store.load("does-not-exist")


def test_no_factory_roots_still_works(user_root):
    store = ProfileStore(user_root)
    assert store.list() == []
    store.save("first", {"name": "first", "controls": {}})
    items = store.list()
    assert items[0]["name"] == "first"
    assert items[0]["factory"] is False
