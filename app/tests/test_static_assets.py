"""Static-asset checks for the design mock and embedded fonts."""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MOCK = REPO_ROOT / "docs" / "mock" / "dashboard.html"
FONTS = REPO_ROOT / "app" / "static" / "fonts"


def test_mock_has_no_external_assets():
    html = MOCK.read_text()
    for needle in ('src="http', "src='http", 'href="http', "href='http"):
        assert needle not in html


def test_required_fonts_exist():
    names = {p.name for p in FONTS.glob("*.woff2")}
    assert any("inter" in n.lower() for n in names)
    assert any("jetbrains" in n.lower() for n in names)
