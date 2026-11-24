"""FastAPI application factory for the usbcopy dashboard."""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from usbcopy import __version__
from usbcopy.api import build_api_router
from usbcopy.auth import SessionManager
from usbcopy.config import Config

APP_DIR = Path(__file__).resolve().parent.parent


def create_app(config: Config, *, start_background: bool = True) -> FastAPI:
    """Build the dashboard application.

    Background watchers and the copy worker are intentionally not started
    here; Task 13 wires them behind ``start_background``. This task only
    mounts the read-only API, the session layer, and the health check.
    """
    app = FastAPI(
        title="usbcopy",
        version=__version__,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    session_manager = SessionManager(config.session_secret)
    app.state.config = config
    app.state.session_manager = session_manager
    app.state.start_background = start_background
    app.state.templates = Jinja2Templates(directory=str(APP_DIR / "templates"))
    app.mount(
        "/static",
        StaticFiles(directory=str(APP_DIR / "static")),
        name="static",
    )
    app.include_router(build_api_router(config, session_manager))

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app
