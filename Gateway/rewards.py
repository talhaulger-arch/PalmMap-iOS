"""SSV-backed reward sessions with bounded, attested SDK revenue estimates.

SSV proves completion, NOT the amount of revenue. App Check, immutable
sessions, per-event/day caps and the separate estimate ledger limit exposure.
Do not advertise the 3x/5x ratio as guaranteed finalized income.
"""
from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import hashlib
import re
import secrets
import threading
import time
from urllib.parse import parse_qsl

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from google.cloud import firestore
import requests

import config
import store
from reward_policy import allocate, reward_price, validate_revenue

SESSIONS = "palmmap_ad_sessions"
RECEIPTS = "palmmap_ad_receipts"
LIMITS = "palmmap_ad_daily_limits"
KEY_URL = "https://www.gstatic.com/admob/reward/verifier-keys.json"
_keys: dict[str, object] = {}
_keys_until = 0.0
_key_lock = threading.Lock()


def _now():
    return datetime.now(timezone.utc)


def _enabled():
    if not config.REWARDED_ADS_ENABLED:
        raise store.EntitlementError("rewards_not_configured", 503)


def _get_key(key_id: str):
    global _keys, _keys_until
    with _key_lock:
        if time.monotonic() >= _keys_until or key_id not in _keys:
            response = requests.get(KEY_URL, timeout=10)
            response.raise_for_status()
            value = response.json()
            keys = {}
            for item in value.get("keys", []):
                key = serialization.load_pem_public_key(item["pem"].encode())
                if isinstance(key, ec.EllipticCurvePublicKey):
                    keys[str(item["keyId"])] = key
            if not keys:
                raise ValueError("admob_keys_unavailable")
            _keys = keys
            _keys_until = time.monotonic() + 3600
        key = _keys.get(key_id)
    if key is None:
        raise ValueError("unknown_admob_key")
    return key


def verify_ssv(raw_query: bytes) -> dict[str, str]:
    """Verify original query bytes without sorting, decoding or rebuilding them."""
    if len(raw_query) > 8192:
        raise ValueError("invalid_ssv")
    try:
        query = raw_query.decode("ascii")
        signed, suffix = query.rsplit("&signature=", 1)
        signature, key_id = suffix.split("&key_id=", 1)
        if not re.fullmatch(r"[0-9]{1,20}", key_id):
            raise ValueError("invalid_ssv_key")
        pairs = parse_qsl(query, keep_blank_values=True, strict_parsing=True)
        params = dict(pairs)
        if len(params) != len(pairs):
            raise ValueError("duplicate_ssv_parameter")
        sig = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
        _get_key(key_id).verify(sig, signed.encode("ascii"), ec.ECDSA(hashes.SHA256()))
    except (InvalidSignature, UnicodeError, KeyError, TypeError, ValueError) as exc:
        raise ValueError("invalid_ssv_signature") from exc
    required = ("transaction_id", "timestamp", "ad_unit", "custom_data", "user_id")
    if any(not params.get(k) for k in required):
        raise ValueError("missing_ssv_parameter")
    try:
        stamp = int(params["timestamp"]) / 1000
    except ValueError as exc:
        raise ValueError("invalid_ssv_timestamp") from exc
    if abs(time.time() - stamp) > 24 * 3600:
        raise ValueError("expired_ssv")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", params["transaction_id"]):
        raise ValueError("invalid_ssv_transaction")
    return params


def wallet(uid: str) -> dict:
    snap = store.db().collection(store.ENTITLEMENTS).document(uid).get()
    data = snap.to_dict() if snap.exists else {}
    balance = max(0, int((data or {}).get("reward_gold") or 0))
    price = reward_price(config.REWARD_AI_COST_MICROS, config.REWARD_MULTIPLIER)
    return {
        "enabled": config.REWARDED_ADS_ENABLED,
        "gold": balance,
        "analysis_gold": price,
        "reward_credits": max(0, int((data or {}).get("reward_credits") or 0)),
        "reward_grants_total": max(0, int((data or {}).get("reward_grants_total") or 0)),
        "max_gold_per_ad": config.REWARD_MAX_VALUE_MICROS,
        "estimated": True,
        "entitlement": store._public_entitlement(data),
    }


def begin(uid: str, *, ad_unit: str | None = None) -> dict:
    _enabled()
    ad_unit = ad_unit or config.REWARDED_AD_UNIT
    client = store.db()
    # One non-PII session ID is sent to AdMob; raw account identity is not.
    session_id = secrets.token_hex(24)
    ref = client.collection(SESSIONS).document(session_id)
    day = _now().strftime("%Y-%m-%d")
    quota = client.collection(LIMITS).document(store.token_hash(uid + ":" + day))
    transaction = client.transaction()

    @firestore.transactional
    def apply(tx):
        q = quota.get(transaction=tx)
        count = int((q.to_dict() or {}).get("sessions", 0)) if q.exists else 0
        if count >= config.REWARD_DAILY_LIMIT:
            raise store.EntitlementError("reward_daily_limit", 429)
        tx.set(quota, {"uid": uid, "day": day, "sessions": count + 1,
                       "expires_at": _now() + timedelta(days=3)}, merge=True)
        tx.create(ref, {
            "uid": uid, "ssv_user": session_id, "ad_unit": ad_unit,
            "created_at": _now(), "expires_at": _now() + timedelta(hours=2),
            "price": reward_price(config.REWARD_AI_COST_MICROS, config.REWARD_MULTIPLIER),
            "max_value": config.REWARD_MAX_VALUE_MICROS, "settled": False,
        })
    apply(transaction)
    return {"session_id": session_id, "custom_data": session_id, "ssv_user": session_id,
            "ad_unit_id": ad_unit, "max_gold": config.REWARD_MAX_VALUE_MICROS}


def _settle(tx, session_ref, data, entitlement_ref, ent):
    if data.get("settled") or not data.get("ssv_verified") or "revenue_micros" not in data:
        return None
    if data.get("account_deleted"):
        return None
    value = int(data["revenue_micros"])
    previous_credits = int(ent.get("reward_credits") or 0)
    balance, credits = allocate(int(ent.get("reward_gold") or 0), value,
                               int(data["price"]), previous_credits)
    tx.set(entitlement_ref, {
        "reward_gold": balance, "reward_credits": credits,
        "reward_grants_total": int(ent.get("reward_grants_total") or 0) + credits - previous_credits,
        "reward_lifetime_estimated_micros": int(ent.get("reward_lifetime_estimated_micros") or 0) + value,
        "updated_at": firestore.SERVER_TIMESTAMP,
    }, merge=True)
    tx.set(session_ref, {"settled": True, "gold_earned": value,
                        "settled_at": firestore.SERVER_TIMESTAMP}, merge=True)
    return value


def record_revenue(uid: str, body: dict) -> dict:
    _enabled()
    session_id = str(body.get("session_id") or "")
    if not re.fullmatch(r"[a-f0-9]{48}", session_id):
        raise store.EntitlementError("invalid_reward_session", 400)
    client = store.db()
    ref = client.collection(SESSIONS).document(session_id)
    ent_ref = client.collection(store.ENTITLEMENTS).document(uid)
    transaction = client.transaction()

    @firestore.transactional
    def apply(tx):
        snap = ref.get(transaction=tx)
        ent_snap = ent_ref.get(transaction=tx)
        data = snap.to_dict() if snap.exists else {}
        if not data or data.get("uid") != uid or data.get("account_deleted"):
            raise store.EntitlementError("reward_session_not_found", 404)
        if data.get("settled"):
            return "settled"
        if data["expires_at"] < _now():
            raise store.EntitlementError("reward_session_expired", 409)
        try:
            value, precision = validate_revenue(body, int(data["max_value"]))
        except ValueError as exc:
            raise store.EntitlementError(str(exc), 400) from exc
        if "revenue_micros" in data and data["revenue_micros"] != value:
            raise store.EntitlementError("reward_value_already_recorded", 409)
        update = {"revenue_micros": value, "revenue_precision": precision,
                  "revenue_currency": "USD", "revenue_received_at": firestore.SERVER_TIMESTAMP}
        data.update(update)
        result = _settle(tx, ref, data, ent_ref, ent_snap.to_dict() or {})
        tx.set(ref, update, merge=True)
        return "settled" if result is not None else "awaiting_verification"
    status = apply(transaction)
    return {"status": status, "wallet": wallet(uid)}


def confirm_ssv(params: dict[str, str]) -> bool:
    _enabled()
    session_id = params["custom_data"]
    if not re.fullmatch(r"[a-f0-9]{48}", session_id):
        return False  # Signed dashboard verification sample; no reward.
    client = store.db()
    ref = client.collection(SESSIONS).document(session_id)
    receipt = client.collection(RECEIPTS).document(store.token_hash(params["transaction_id"]))
    transaction = client.transaction()

    @firestore.transactional
    def apply(tx):
        old = receipt.get(transaction=tx)
        snap = ref.get(transaction=tx)
        if old.exists:
            return True
        data = snap.to_dict() if snap.exists else {}
        if not data or data.get("account_deleted"):
            return False
        # SSV ad_unit may be the numeric unit suffix, not the full SDK ID.
        expected_units = {data["ad_unit"], data["ad_unit"].split("/")[-1]}
        if params["ad_unit"] not in expected_units or params["user_id"] != data["ssv_user"]:
            raise store.EntitlementError("reward_ssv_mismatch", 400)
        if data["expires_at"] < _now():
            return False
        if data.get("ssv_verified"):
            # A second transaction for one show can never grant another reward.
            return True
        ent_ref = client.collection(store.ENTITLEMENTS).document(data["uid"])
        ent_snap = ent_ref.get(transaction=tx)
        data["ssv_verified"] = True
        _settle(tx, ref, data, ent_ref, ent_snap.to_dict() or {})
        tx.set(ref, {"ssv_verified": True, "transaction_hash": receipt.id}, merge=True)
        tx.create(receipt, {"session_id": session_id, "received_at": firestore.SERVER_TIMESTAMP})
        return True
    return apply(transaction)
