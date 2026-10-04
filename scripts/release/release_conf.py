"""Read scripts/release/release.conf, the constants shared with the shell scripts."""

from __future__ import annotations

from pathlib import Path

CONF_PATH = Path(__file__).resolve().with_name("release.conf")


def load(path: Path = CONF_PATH) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator:
            raise ValueError(f"{path}: not KEY=VALUE: {line}")
        values[key] = value
    return values


def get(key: str) -> str:
    value = load().get(key)
    if not value:
        raise KeyError(f"release.conf has no {key}")
    return value
