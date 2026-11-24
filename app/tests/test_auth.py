from __future__ import annotations

import time

from usbcopy.auth import Session, SessionManager, hash_password, verify_password


def test_password_roundtrip():
    h = hash_password("correct horse")
    assert verify_password("correct horse", h) and not verify_password("wrong", h)


def test_password_hash_is_salted_and_not_plaintext():
    first = hash_password("correct horse")
    second = hash_password("correct horse")
    assert "correct horse" not in first
    assert first != second


def test_overlong_password_never_matches():
    h = hash_password("short password")
    assert verify_password("x" * 100, h) is False


def test_session_roundtrip_and_csrf():
    sm = SessionManager("secret")
    token = sm.create("admin")
    session = sm.read(token)
    assert isinstance(session, Session)
    assert session.username == "admin" and len(session.csrf) >= 32


def test_each_session_has_a_distinct_csrf_token():
    sm = SessionManager("secret")
    first = sm.read(sm.create("admin"))
    second = sm.read(sm.create("admin"))
    assert first.csrf != second.csrf


def test_tampered_session_rejected():
    sm = SessionManager("secret")
    assert sm.read(sm.create("admin") + "x") is None


def test_garbage_token_rejected():
    assert SessionManager("secret").read("not-a-token") is None


def test_session_signed_with_another_secret_rejected():
    token = SessionManager("secret").create("admin")
    assert SessionManager("other secret").read(token) is None


def test_fresh_session_accepted_within_max_age():
    sm = SessionManager("secret", max_age_seconds=60)
    session = sm.read(sm.create("admin"))
    assert session is not None and session.username == "admin"


def test_expired_session_rejected(monkeypatch):
    sm = SessionManager("secret", max_age_seconds=1)
    token = sm.create("admin")
    real_time = time.time
    monkeypatch.setattr(time, "time", lambda: real_time() + 10)
    assert sm.read(token) is None
