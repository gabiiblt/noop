#!/usr/bin/env python3
"""Thin wrapper: `python tools/push_simulator.py ...` == `noop-push-simulator ...`."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))
from noop_selfhost.simulator import main  # noqa: E402

if __name__ == "__main__":
    main()
