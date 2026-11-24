"""Media classification hints for usbcopy.

A hint is a suggestion only: the user's selection decides what is copied.
Classification is a pure function of the drive-relative path; it never
touches the filesystem.
"""

from __future__ import annotations

import re
from typing import Literal

VIDEO_EXTENSIONS: frozenset[str] = frozenset(
    {
        "mkv",
        "mp4",
        "m4v",
        "avi",
        "mov",
        "wmv",
        "webm",
        "ts",
        "m2ts",
        "mpg",
        "mpeg",
        "flv",
        "3gp",
    }
)

TV_PATTERN: re.Pattern[str] = re.compile(
    r"[Ss]\d{1,2}[Ee]\d{1,3}"
    r"|(?<!\d)\d{1,2}x\d{1,3}(?!\d)"
    r"|(?:^|/)(?i:season) \d+(?:/|$)"
)


def classify(rel_path: str) -> Literal["movie", "series", "other"]:
    """Return a copy suggestion for a path relative to the drive root."""
    if _extension(rel_path) not in VIDEO_EXTENSIONS:
        return "other"
    if TV_PATTERN.search(rel_path):
        return "series"
    return "movie"


def _extension(rel_path: str) -> str:
    name = rel_path.rsplit("/", 1)[-1]
    _, dot, extension = name.rpartition(".")
    return extension.lower() if dot else ""
