"""Password hashing and signed sessions for the usbcopy dashboard.

Plaintext passwords never leave the caller: this module produces bcrypt
hashes only. Session tokens are signed with the configured secret and carry
just the username and a CSRF token.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass

from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from passlib.context import CryptContext

DEFAULT_SESSION_MAX_AGE_SECONDS = 12 * 3600
CSRF_TOKEN_BYTES = 32
MIN_PASSWORD_LENGTH = 12

_BCRYPT_MAX_PASSWORD_BYTES = 72
_SESSION_SALT = "usbcopy.session"

_PASSWORDS = CryptContext(schemes=["bcrypt"])


@dataclass(frozen=True)
class Session:
    """The data carried inside a signed session cookie."""

    username: str
    csrf: str


def hash_password(password: str) -> str:
    """Return a salted bcrypt hash suitable for storing in config."""
    return _PASSWORDS.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    """Return True when ``password`` matches the stored bcrypt hash."""
    if len(password.encode("utf-8")) > _BCRYPT_MAX_PASSWORD_BYTES:
        return False
    return _PASSWORDS.verify(password, password_hash)


class SessionManager:
    """Create and verify signed, expiring session tokens."""

    def __init__(
        self,
        secret: str,
        max_age_seconds: int = DEFAULT_SESSION_MAX_AGE_SECONDS,
    ) -> None:
        self._serializer = URLSafeTimedSerializer(secret, salt=_SESSION_SALT)
        self._max_age_seconds = max_age_seconds

    def create(self, username: str) -> str:
        """Return a signed token for ``username`` carrying a fresh CSRF token."""
        csrf = secrets.token_urlsafe(CSRF_TOKEN_BYTES)
        return self._serializer.dumps({"username": username, "csrf": csrf})

    def read(self, token: str) -> Session | None:
        """Return the session in ``token``, or None if it is invalid or expired."""
        try:
            payload = self._serializer.loads(token, max_age=self._max_age_seconds)
        except (BadSignature, SignatureExpired):
            return None
        if not isinstance(payload, dict):
            return None
        username = payload.get("username")
        csrf = payload.get("csrf")
        if not isinstance(username, str) or not isinstance(csrf, str):
            return None
        if not username or len(csrf) < CSRF_TOKEN_BYTES:
            return None
        return Session(username=username, csrf=csrf)
