import json
import pathlib

from noop_selfhost.registry import registry_json

FIXTURE = (pathlib.Path(__file__).resolve().parents[2]
           / "Packages/SelfHostPush/Tests/SelfHostPushTests/Fixtures/registry.json")


def test_swift_parity_fixture_matches_python_registry():
    """The Swift client's PushRegistry is checked against this same file (RegistryParityTests)."""
    assert json.loads(FIXTURE.read_text()) == registry_json(), (
        "registry changed: regenerate with `python -m noop_selfhost.registry > " + str(FIXTURE) + "` "
        "and update Packages/SelfHostPush/Sources/SelfHostPush/StreamSpec.swift to match")
