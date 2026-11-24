"""Process entry point: load configuration and serve the dashboard."""

from __future__ import annotations

import logging
import os
from pathlib import Path

import uvicorn

from usbcopy.app import create_app
from usbcopy.config import load_config

DEFAULT_CONFIG_PATH = Path("/etc/usbcopy/config.toml")
CONFIG_PATH_ENV = "USBCOPY_CONFIG"


def config_path() -> Path:
    """Return the configured path, honouring the environment override."""
    override = os.environ.get(CONFIG_PATH_ENV)
    if override:
        return Path(override)
    return DEFAULT_CONFIG_PATH


def main() -> None:
    """Load the runtime configuration and serve uvicorn on its port."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    config = load_config(config_path())
    app = create_app(config)
    uvicorn.run(app, host="0.0.0.0", port=config.port)


if __name__ == "__main__":
    main()
