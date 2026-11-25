"""Static-asset checks for the design mock and embedded fonts."""

from pathlib import Path

import yaml

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


def _markdown_lines(text: str):
    in_fence = False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence:
            yield line


def _markdown_prose(text: str) -> str:
    return " ".join(" ".join(_markdown_lines(text)).split()).lower()


def _readme_headings(text: str) -> set[str]:
    headings = set()
    for line in _markdown_lines(text):
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
    text = _markdown_prose(README.read_text())
    assert "keeps the ct" in text
    assert "destination files" in text


def test_readme_states_source_and_copy_safety():
    text = _markdown_prose(README.read_text())
    for phrase in (
        "read-only",
        "copy-only",
        "never writes, moves, or deletes",
        "never overwritten",
        "atomic",
        "persistent history",
        "persists while the app is installed",
        "preview-only",
        "attempted file",
    ):
        assert phrase in text
    assert "permanent" not in text


def test_readme_has_no_placeholder_install_commands():
    text = README.read_text().lower()
    assert "<owner>" not in text
    assert "git clone" not in text
    assert "raw.githubusercontent.com" not in text
    assert "curl -fssl" not in text


def test_readme_documents_exact_noninteractive_answer_stream():
    text = README.read_text()
    prose = _markdown_prose(text)
    assert (
        "CTID hostname storage disk-GB RAM-MB cores network movies series "
        "extra source auto port [password]"
    ) in text
    assert "14 tokens when you supply the optional password" in prose
    assert "13 required tokens" in prose
    assert "14th password token" in prose
    assert "swap is forced to 512 mb" in prose
    assert "static networking" in prose
    assert "three more tokens" in prose
    assert "movies and series are required" in prose
    assert "`--yes` alone fails" in prose


def test_readme_review_opens_at_drive_root():
    prose = _markdown_prose(README.read_text())
    assert "review always opens at the drive root" in prose
    assert "browse from the drive root" in prose
    assert "start at the configured source folder" not in prose


def test_readme_documents_template_and_destination_requirements():
    prose = _markdown_prose(README.read_text())
    assert "vztmpl" in prose
    assert "hard links" in prose
    assert "fat and exfat destinations are not supported" in prose
    assert "256 mib" in prose
    assert "256 mb" not in prose


def test_troubleshooting_doc_covers_common_failures():
    text = _markdown_prose(TROUBLESHOOTING.read_text())
    for phrase in (
        "drive not detected",
        "unsupported filesystem",
        "destination filesystem",
        "hard links",
        "permission",
        "port",
        "conflict",
        "healthz",
        "systemctl status usbcopy",
        "/srv/usbcopy/events",
        "rollback",
    ):
        assert phrase in text
    assert "100000 + ct id" not in text
    assert "100000 + container id" not in text


def test_troubleshooting_uses_usbcopy_uid_for_mapped_owner():
    text = _markdown_prose(TROUBLESHOOTING.read_text())
    assert "100000 + the uid/gid of usbcopy inside the ct" in text
    assert "id -u usbcopy" in text
    assert "100000 + ct id" not in text
    assert "100000 + container id" not in text


def test_troubleshooting_corrects_port_scan_and_rollback_wording():
    full_text = TROUBLESHOOTING.read_text().lower()
    text = _markdown_prose(TROUBLESHOOTING.read_text())
    assert "sed -i" in full_text
    assert "vi /etc/usbcopy" not in full_text
    assert "skips already-mounted drives" in text
    assert "startup scan" in text
    assert "recreate notifications for drives that are already mounted" not in text
    assert "write-manifest stage" in text
    assert "no supported uninstall record" in text
    assert "later install is blocked only when a manifest already exists" in text
    assert "manifest may remain" not in text
    assert "later install will refuse" not in text


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
    data = yaml.safe_load(CI_WORKFLOW.read_text())
    assert set(data["jobs"]) == {"python", "shell"}
