"""Firebase bearer authentication and privacy guards."""

from __future__ import annotations

import hashlib
import hmac
from typing import Any

import firebase_admin
from firebase_admin import auth

from config import PROJECT_ID


class AuthError(Exception):
    pass


def _ensure_firebase() -> None:
    try:
        firebase_admin.get_app()
    except ValueError:
        firebase_admin.initialize_app(options={"projectId": PROJECT_ID})


def verify_bearer(value: str | None) -> dict[str, Any]:
    if not value or not value.startswith("Bearer ") or value.count(" ") != 1:
        raise AuthError("missing_or_invalid_bearer")
    token = value[7:].strip()
    if not token or len(token) > 4096:
        raise AuthError("missing_or_invalid_bearer")
    _ensure_firebase()
    try:
        decoded = auth.verify_id_token(token, check_revoked=True)
    except Exception as exc:
        raise AuthError("invalid_or_expired_firebase_token") from exc
    uid = str(decoded.get("uid") or decoded.get("sub") or "").strip()
    if not uid or len(uid) > 128:
        raise AuthError("invalid_firebase_uid")
    decoded["uid"] = uid
    return decoded


def delete_firebase_user(uid: str) -> None:
    """Permanently remove the authenticated PalmMap Firebase account."""
    _ensure_firebase()
    auth.delete_user(uid)


def obfuscated_account_id(uid: str) -> str:
    return hashlib.sha256(("palmmap:" + uid).encode("utf-8")).hexdigest()


def account_matches(uid: str, received: str | None) -> bool:
    expected = obfuscated_account_id(uid)
    return bool(received) and hmac.compare_digest(expected, str(received))


_BLOCKED_EXACT_KEYS = {
    "photo",
    "photos",
    "image",
    "images",
    "email",
    "profile_name",
    "display_name",
    "user_name",
    "name",
    "full_name",
    "birth_date",
    "birth_date_iso",
    "date_of_birth",
    "marriage_date",
    "marriage_date_iso",
}


def assert_source_safe(value: Any) -> None:
    """Reject accidental identity/photo fields before they reach the AI worker."""
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).strip().lower() in _BLOCKED_EXACT_KEYS:
                raise ValueError("identity_or_photo_field_not_allowed")
            assert_source_safe(child)
    elif isinstance(value, list):
        for child in value:
            assert_source_safe(child)
