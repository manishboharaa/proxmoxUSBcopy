from __future__ import annotations

import re
from typing import get_args, get_type_hints

import pytest

from usbcopy.media import TV_PATTERN, VIDEO_EXTENSIONS, classify

MEDIA_KINDS = {"movie", "series", "other"}

VIDEO_EXTENSION_NAMES = sorted(
    [f"Movies/Film.{ext}" for ext in VIDEO_EXTENSIONS]
    + [f"Movies/Film.{ext.upper()}" for ext in VIDEO_EXTENSIONS]
)


@pytest.mark.parametrize(
    "path,expected",
    [
        ("Movies/Heat (1995)/Heat.mkv", "movie"),
        ("Shows/The Wire/Season 2/S02E03.mkv", "series"),
        ("Shows/The Wire/S02E03.MKV", "series"),
        ("Shows/1x02 - title.mp4", "series"),
        ("notes.txt", "other"),
        ("poster.jpg", "other"),
    ],
)
def test_classify(path, expected):
    assert classify(path) == expected


def test_video_extensions_are_exactly_the_supported_set():
    assert isinstance(VIDEO_EXTENSIONS, frozenset)
    assert VIDEO_EXTENSIONS == frozenset(
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


@pytest.mark.parametrize("path", VIDEO_EXTENSION_NAMES)
def test_video_extension_variants_are_movies(path):
    assert classify(path) == "movie"


@pytest.mark.parametrize(
    "path",
    [
        "Shows/The Wire/S01E02.mkv",
        "Shows/The Wire/s1e2.MKV",
        "Shows/The Wire/S12E345.mkv",
        "Shows/The Wire/1x02 - title.mp4",
        "Shows/The Wire/12x345 - title.avi",
        "Shows/Breaking Bad/Season 5/Episode One.mkv",
    ],
)
def test_tv_naming_marks_video_as_series(path):
    assert classify(path) == "series"


@pytest.mark.parametrize(
    "path",
    [
        "Movies/Heat (1995)/Heat.mkv",
        "Movies/Heat.1995.1080p.BluRay.mkv",
        "Movies/documentary.m2ts",
    ],
)
def test_video_without_tv_naming_is_movie(path):
    assert classify(path) == "movie"


@pytest.mark.parametrize(
    "path",
    [
        "Shows/The Wire/S02E03.srt",
        "Shows/The Wire/Season 2/poster.jpg",
        "notes.txt",
    ],
)
def test_non_video_stays_other_even_with_tv_naming(path):
    assert classify(path) == "other"


@pytest.mark.parametrize(
    "path",
    ["", "Movies/README", "Movies/Heat (1995)/Heat.", "Shows/Season 2"],
)
def test_paths_without_video_extension_are_other(path):
    assert classify(path) == "other"


def test_tv_pattern_is_a_compiled_regex():
    assert isinstance(TV_PATTERN, re.Pattern)


@pytest.mark.parametrize("text", ["S01E02", "s1e2", "1x02", "Season 3"])
def test_tv_pattern_matches_tv_tokens(text):
    assert TV_PATTERN.search(text) is not None


@pytest.mark.parametrize("text", ["Heat (1995)", "notes.txt", "S01", "E02"])
def test_tv_pattern_ignores_non_tv_text(text):
    assert TV_PATTERN.search(text) is None


def test_classify_return_annotation_declares_exact_vocabulary():
    return_type = get_type_hints(classify)["return"]
    assert set(get_args(return_type)) == MEDIA_KINDS


def test_classify_uses_only_the_declared_vocabulary():
    outputs = {
        classify(path)
        for path in [
            "Movies/Heat (1995)/Heat.mkv",
            "Shows/The Wire/Season 2/S02E03.mkv",
            "notes.txt",
        ]
    }
    assert outputs == MEDIA_KINDS
