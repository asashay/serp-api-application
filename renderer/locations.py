"""Exit IP targeting for the search locations in config/locations.json.

Rails sends a location's name; only names from the shared list map to
DataImpulse targeting parameters, so a request cannot choose its own.
"""

import json
from pathlib import Path

PATH = Path(__file__).resolve().parent.parent / "config" / "locations.json"
TARGETING = {entry["name"]: entry["proxy"] for entry in json.loads(PATH.read_text())}


def targeting(name):
    """(True, parameters) for a known name or None, else (False, None)."""
    if name is None:
        return True, None
    if isinstance(name, str) and name in TARGETING:
        return True, TARGETING[name]
    return False, None
