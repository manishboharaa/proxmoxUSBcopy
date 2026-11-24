"""Static-asset checks for the design mock and embedded fonts."""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MOCK = REPO_ROOT / "docs" / "mock" / "dashboard.html"
FONTS = REPO_ROOT / "app" / "static" / "fonts"
IMPORT_JS = REPO_ROOT / "app" / "static" / "js" / "import.js"


def test_mock_has_no_external_assets():
    html = MOCK.read_text()
    for needle in ('src="http', "src='http", 'href="http', "href='http"):
        assert needle not in html


def test_required_fonts_exist():
    names = {p.name for p in FONTS.glob("*.woff2")}
    assert any("inter" in n.lower() for n in names)
    assert any("jetbrains" in n.lower() for n in names)


def test_import_show_more_pagination_passes_parent_path():
    """Pin the "Show more" call chain that must forward the folder path.

    A browser-level regression test needs a DOM runtime. This project has no
    JavaScript test dependencies and must not add any, so this focused static
    check guards the exact bug: ``appendEntries`` must receive ``parent`` as a
    parameter and pass it to ``loadChildren``. An unbound ``parent`` resolves
    to ``window.parent`` in the browser and breaks pagination.
    """
    script = IMPORT_JS.read_text()
    assert "function appendEntries(list, parent, offset, body)" in script
    assert (
        "appendEntries(list, parent, append ? offset : 0, result.body)"
        in script
    )
    assert "loadChildren(list, parent, nextOffset, true)" in script
    assert "appendEntries(list, offset, body)" not in script
    assert "window.parent" not in script
