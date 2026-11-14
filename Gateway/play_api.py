"""Server-side Google Play purchase verification and settlement."""

from __future__ import annotations

import threading
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote

import google.auth
from google.auth.transport.requests import Request
import requests

from config import ALLOWED_BASE_PLANS, PACKAGE_NAME
from security import account_matches


ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
API_ROOT = "https://androidpublisher.googleapis.com/androidpublisher/v3"
_credentials = None
_lock = threading.Lock()


class PlayError(Exception):
    def __init__(self, code: str, status: int = 400):
        super().__init__(code)
        self.code = code
        self.status = status


def _token() -> str:
    global _credentials
    with _lock:
        if _credentials is None:
            _credentials, _ = google.auth.default(scopes=[ANDROID_PUBLISHER_SCOPE])
        if not _credentials.valid or not _credentials.token:
            _credentials.refresh(Request())
        return str(_credentials.token)


def _request(method: str, path: str, body: dict | None = None) -> dict[str, Any]:
    try:
        response = requests.request(
            method,
            API_ROOT + path,
            headers={"Authorization": "Bearer " + _token(), "Accept": "application/json"},
            json=body,
            timeout=30,
        )
    except requests.RequestException as exc:
        raise PlayError("play_api_unavailable", 502) from exc
    if response.status_code >= 400:
        if response.status_code in (401, 403):
            code = "play_console_permission_missing"
        elif response.status_code == 404:
            code = "purchase_not_found"
        else:
            code = "play_verification_failed"
        raise PlayError(code, 502 if response.status_code >= 500 else 400)
    if not response.content:
        return {}
    try:
        return response.json()
    except ValueError as exc:
        raise PlayError("invalid_play_response", 502) from exc


def _q(value: str) -> str:
    return quote(value, safe="")


def _parse_rfc3339(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except (TypeError, ValueError) as exc:
        raise PlayError("invalid_subscription_expiry", 502) from exc


def verify_consumable(uid: str, product_id: str, purchase_token: str) -> dict[str, Any]:
    data = _request(
        "GET",
        f"/applications/{_q(PACKAGE_NAME)}/purchases/productsv2/tokens/{_q(purchase_token)}",
    )
    state = str((data.get("purchaseStateContext") or {}).get("purchaseState") or "")
    if state != "PURCHASED":
        raise PlayError("purchase_not_completed")
    if not account_matches(uid, data.get("obfuscatedExternalAccountId")):
        raise PlayError("purchase_account_mismatch", 403)
    lines = data.get("productLineItem") or []
    matching = [line for line in lines if isinstance(line, dict) and line.get("productId") == product_id]
    if not matching or any(line.get("productId") != product_id for line in lines if isinstance(line, dict)):
        raise PlayError("wrong_product")
    quantity = sum(max(1, int((line.get("productOfferDetails") or {}).get("quantity") or 1)) for line in matching)
    if quantity < 1 or quantity > 10:
        raise PlayError("invalid_quantity")
    return {
        "quantity": quantity,
        "order_id": str(data.get("orderId") or ""),
        "consumption_state": str(matching[0].get("consumptionState") or ""),
    }


def consume(product_id: str, purchase_token: str) -> None:
    _request(
        "POST",
        f"/applications/{_q(PACKAGE_NAME)}/purchases/products/{_q(product_id)}/tokens/{_q(purchase_token)}:consume",
        {},
    )


def verify_subscription(uid: str, product_id: str, purchase_token: str) -> dict[str, Any]:
    data = _request(
        "GET",
        f"/applications/{_q(PACKAGE_NAME)}/purchases/subscriptionsv2/tokens/{_q(purchase_token)}",
    )
    account = (data.get("externalAccountIdentifiers") or {}).get("obfuscatedExternalAccountId")
    if not account_matches(uid, account):
        raise PlayError("purchase_account_mismatch", 403)
    lines = data.get("lineItems") or []
    matching = [line for line in lines if isinstance(line, dict) and line.get("productId") == product_id]
    if not matching or any(line.get("productId") != product_id for line in lines if isinstance(line, dict)):
        raise PlayError("wrong_product")
    base_plans = {
        str((line.get("offerDetails") or {}).get("basePlanId") or "")
        for line in matching
        if (line.get("offerDetails") or {}).get("basePlanId")
    }
    if base_plans and not base_plans.issubset(ALLOWED_BASE_PLANS):
        raise PlayError("wrong_base_plan")
    expiry = max(_parse_rfc3339(str(line.get("expiryTime") or "")) for line in matching)
    state = str(data.get("subscriptionState") or "")
    allowed_states = {"SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", "SUBSCRIPTION_STATE_CANCELED"}
    has_access = state in allowed_states and expiry > datetime.now(timezone.utc)
    return {
        "active": has_access,
        "state": state,
        "expiry": expiry,
        "order_id": str(data.get("latestOrderId") or ""),
        "acknowledgement_state": str(data.get("acknowledgementState") or ""),
    }


def acknowledge_subscription(product_id: str, purchase_token: str) -> None:
    _request(
        "POST",
        f"/applications/{_q(PACKAGE_NAME)}/purchases/subscriptions/{_q(product_id)}/tokens/{_q(purchase_token)}:acknowledge",
        {},
    )

