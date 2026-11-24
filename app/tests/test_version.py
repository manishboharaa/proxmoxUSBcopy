def test_version_is_semver():
    import usbcopy

    assert usbcopy.__version__ == "0.1.0"
