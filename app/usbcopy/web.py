"""Http session helpers and authentication for the usbcopy dashboard."""

from __future__ import annotations

from collections.abc import Callable

from fastapi import HTTPException, Request, Response, status

from usbcopy.auth import DEFAULT_SESSION_MAX_AGE_SECONDS, Session, SessionManager

SESSION_COOKIE = "usbcopy_session"


def build_require_session(
    session_manager: SessionManager,
) -> Callable[[Request], Session]:
    """Return a dependency that resolves the signed session cookie."""

    def require_session(request: Request) -> Session:
        token = request.cookies.get(SESSION_COOKIE)
        if not token:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="authentication required",
            )
        try:
            session = session_manager.read(token)
        except (TypeError, ValueError):
            session = None
        if session is None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired session",
            )
        return session

    return require_session


def set_session_cookie(response: Response, token: str, *, secure: bool) -> None:
    """Set the signed session cookie with HttpOnly and SameSite=Lax."""
    response.set_cookie(
        key=SESSION_COOKIE,
        value=token,
        max_age=DEFAULT_SESSION_MAX_AGE_SECONDS,
        path="/",
        httponly=True,
        samesite="lax",
        secure=secure,
    )


def clear_session_cookie(response: Response, *, secure: bool) -> None:
    """Expire the session cookie in a way that matches how it was set."""
    response.delete_cookie(
        key=SESSION_COOKIE,
        path="/",
        httponly=True,
        samesite="lax",
        secure=secure,
    )
