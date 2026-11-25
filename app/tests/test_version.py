def test_version_is_semver():
    import usbcopy

    parts = usbcopy.__version__.split(".")
    assert len(parts) == 3, usbcopy.__version__
    assert all(part.isdigit() for part in parts), usbcopy.__version__


def test_version_file_matches_package_version():
    from pathlib import Path

    import usbcopy

    version_file = Path(usbcopy.__file__).with_name("VERSION")
    assert version_file.read_text(encoding="utf-8").strip() == usbcopy.__version__
