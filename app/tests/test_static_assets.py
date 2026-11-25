"""Static-asset checks for the design mock and embedded fonts."""

from pathlib import Path

import pytest

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


README = REPO_ROOT / "README.md"
TROUBLESHOOTING = REPO_ROOT / "docs" / "troubleshooting.md"
CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"

REQUIRED_README_SECTIONS = (
    "what it does",
    "requirements",
    "install",
    "dashboard",
    "safety",
    "troubleshooting",
    "uninstall",
    "license",
)


def _readme_headings(text: str) -> set[str]:
    headings = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("#"):
            continue
        title = stripped.lstrip("#").strip().lower()
        if title:
            headings.add(title)
    return headings


def test_readme_has_required_sections():
    headings = _readme_headings(README.read_text())
    for heading in REQUIRED_README_SECTIONS:
        assert heading in headings


def test_readme_documents_real_installer_flags():
    text = README.read_text()
    for flag in (
        "--repo-url",
        "--ref",
        "--dry-run",
        "--yes",
        "--uninstall",
        "--destroy-ct",
    ):
        assert flag in text
    assert "USBC_ANSWERS" in text


def test_readme_says_default_uninstall_keeps_ct_and_destinations():
    text = README.read_text().lower()
    assert "keeps the ct" in text
    assert "destination files" in text


def test_readme_states_source_and_copy_safety():
    text = README.read_text().lower()
    for phrase in (
        "read-only",
        "copy-only",
        "never writes, moves, or deletes",
        "never overwritten",
        "atomic",
        "permanent",
    ):
        assert phrase in text


def test_troubleshooting_doc_covers_common_failures():
    text = TROUBLESHOOTING.read_text().lower()
    for phrase in (
        "drive not detected",
        "unsupported filesystem",
        "permission",
        "port",
        "conflict",
        "healthz",
        "systemctl status usbcopy",
        "/srv/usbcopy/events",
        "rollback",
    ):
        assert phrase in text


def test_ci_workflow_runs_python_and_shell_checks():
    text = CI_WORKFLOW.read_text()
    for phrase in (
        "pytest -q",
        "ruff check .",
        "shellcheck",
        "bash -n",
        "setup/tests/fakes/*",
    ):
        assert phrase in text


def test_ci_workflow_is_valid_yaml():
    yaml = pytest.importorskip("yaml")
    data = yaml.safe_load(CI_WORKFLOW.read_text())
    assert set(data["jobs"]) == {"python", "shell"}
