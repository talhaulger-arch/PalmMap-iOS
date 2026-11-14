"""Firestore-backed entitlement, idempotency and AI result storage."""

from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import uuid4

from google.cloud import firestore

from config import (
    INAPP_PRODUCT_ID,
    MAX_PARTNER_CREDITS,
    MAX_REPORT_CREDITS,
    PARTNER_ANALYSIS_PRODUCT_ID,
    PLUS_MONTHLY_CREDITS,
    PROJECT_ID,
    RELATIONSHIP_AI_POLICY,
)


ENTITLEMENTS = "palmmap_server_entitlements"
PURCHASES = "palmmap_server_purchases"
REPORTS = "palmmap_server_reports"
LEGACY_PREVIEWS = "palmmap_server_previews"
PARTNER_CLAIMS = "palmmap_server_partner_claims"
CONTENT_REPORTS = "palmmap_content_reports"
READING_FEEDBACK = "palmmap_reading_feedback"
_client: firestore.Client | None = None


class EntitlementError(Exception):
    def __init__(self, code: str, status: int = 403):
        super().__init__(code)
        self.code = code
        self.status = status


def db() -> firestore.Client:
    global _client
    if _client is None:
        _client = firestore.Client(project=PROJECT_ID)
    return _client


def token_hash(purchase_token: str) -> str:
    return hashlib.sha256(purchase_token.encode("utf-8")).hexdigest()


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _plus_allowance_update(current: dict[str, Any], active: bool, cycle_key: str) -> dict[str, Any]:
    if active and str(current.get("plus_allowance_cycle") or "") != cycle_key:
        return {
            "plus_allowance_cycle": cycle_key,
            "plus_credits_remaining": PLUS_MONTHLY_CREDITS,
        }
    return {}


def _select_credit_source(
    public: dict[str, Any], one_time_field: str, one_time_source: str, missing_error: str, *, reward_only: bool = False
) -> str:
    if reward_only:
        if public.get("reward_credits", 0) > 0:
            return "reward"
        raise EntitlementError("reward_credit_required", 402)
    if public["subscription_active"] and public["plus_credits_remaining"] > 0:
        return "plus"
    if public.get("reward_credits", 0) > 0:
        return "reward"
    if public[one_time_field] > 0:
        return one_time_source
    if public["subscription_active"]:
        raise EntitlementError("plus_monthly_limit_reached", 402)
    raise EntitlementError(missing_error, 402)


def _active_plus_prefix(data: dict[str, Any]) -> str | None:
    now = _utcnow()
    for prefix in ("", "apple_"):
        expiry = data.get(prefix + "subscription_expiry")
        if data.get(prefix + "subscription_active") and isinstance(expiry, datetime) and expiry > now:
            return prefix
    return None


def _credit_field(data: dict[str, Any], source: str, one_time: str) -> str:
    if source == "plus":
        return (_active_plus_prefix(data) or "") + "plus_credits_remaining"
    if source == "reward":
        return "reward_credits"
    return one_time if int(data.get(one_time) or 0) > 0 else "apple_" + one_time


def _public_entitlement(data: dict[str, Any] | None) -> dict[str, Any]:
    data = data or {}
    active_prefix = _active_plus_prefix(data)
    prefix = active_prefix or ""
    expiry = data.get(prefix + "subscription_expiry") or data.get("apple_subscription_expiry")
    plus_remaining = max(0, min(PLUS_MONTHLY_CREDITS, int(data.get(prefix + "plus_credits_remaining") or 0))) if active_prefix is not None else 0
    return {
        "subscription_active": active_prefix is not None,
        "subscription_expiry": expiry.isoformat().replace("+00:00", "Z") if isinstance(expiry, datetime) else None,
        "plus_credits_remaining": plus_remaining,
        "plus_credits_limit": PLUS_MONTHLY_CREDITS,
        "report_credits": max(0, int(data.get("report_credits") or 0)) + max(0, int(data.get("apple_report_credits") or 0)),
        "partner_credits": max(0, int(data.get("partner_credits") or 0)) + max(0, int(data.get("apple_partner_credits") or 0)),
        "reward_credits": max(0, int(data.get("reward_credits") or 0)),
    }


def get_entitlement(uid: str) -> dict[str, Any]:
    snap = db().collection(ENTITLEMENTS).document(uid).get()
    return _public_entitlement(snap.to_dict() if snap.exists else None)


def get_subscription_reference(uid: str) -> dict[str, str] | None:
    """Return a server-only Play token; this value is never serialized to a client."""
    snap = db().collection(ENTITLEMENTS).document(uid).get()
    data = snap.to_dict() if snap.exists else {}
    token = str((data or {}).get("subscription_purchase_token") or "")
    product_id = str((data or {}).get("subscription_product_id") or "")
    if not token or not product_id:
        return None
    return {"purchase_token": token, "product_id": product_id}


def grant_consumable(uid: str, purchase_token: str, product_id: str, quantity: int, order_id: str) -> tuple[bool, dict[str, Any]]:
    client = db()
    entitlement_ref = client.collection(ENTITLEMENTS).document(uid)
    purchase_ref = client.collection(PURCHASES).document(token_hash(purchase_token))
    transaction = client.transaction()

    @firestore.transactional
    def apply(transaction):
        purchase_snap = purchase_ref.get(transaction=transaction)
        if purchase_snap.exists:
            old = purchase_snap.to_dict() or {}
            if old.get("uid") != uid or old.get("product_id") != product_id:
                raise EntitlementError("purchase_token_already_claimed", 409)
            entitlement_snap = entitlement_ref.get(transaction=transaction)
            return False, _public_entitlement(entitlement_snap.to_dict() if entitlement_snap.exists else None)
        entitlement_snap = entitlement_ref.get(transaction=transaction)
        current = entitlement_snap.to_dict() if entitlement_snap.exists else {}
        if product_id == INAPP_PRODUCT_ID:
            credit_field = "report_credits"
            credit_limit = MAX_REPORT_CREDITS
        elif product_id == PARTNER_ANALYSIS_PRODUCT_ID:
            credit_field = "partner_credits"
            credit_limit = MAX_PARTNER_CREDITS
        else:
            raise EntitlementError("wrong_product", 400)
        credits = min(credit_limit, max(0, int((current or {}).get(credit_field) or 0)) + quantity)
        transaction.set(entitlement_ref, {credit_field: credits, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True)
        transaction.create(
            purchase_ref,
            {
                "uid": uid,
                "product_id": product_id,
                "product_type": "inapp",
                "order_id": order_id,
                "quantity": quantity,
                "settled": False,
                "verified_at": firestore.SERVER_TIMESTAMP,
            },
        )
        current = dict(current or {})
        current[credit_field] = credits
        return True, _public_entitlement(current)

    return apply(transaction)


def mark_consumed(purchase_token: str) -> None:
    db().collection(PURCHASES).document(token_hash(purchase_token)).set(
        {"settled": True, "settled_at": firestore.SERVER_TIMESTAMP}, merge=True
    )


def record_subscription(
    uid: str,
    purchase_token: str,
    product_id: str,
    active: bool,
    state: str,
    expiry: datetime,
    order_id: str,
) -> dict[str, Any]:
    client = db()
    entitlement_ref = client.collection(ENTITLEMENTS).document(uid)
    purchase_ref = client.collection(PURCHASES).document(token_hash(purchase_token))
    transaction = client.transaction()

    @firestore.transactional
    def apply(transaction):
        old = purchase_ref.get(transaction=transaction)
        if old.exists and (old.to_dict() or {}).get("uid") != uid:
            raise EntitlementError("purchase_token_already_claimed", 409)
        entitlement_snap = entitlement_ref.get(transaction=transaction)
        current = entitlement_snap.to_dict() if entitlement_snap.exists else {}
        current_expiry = current.get("subscription_expiry")
        current_active = (
            bool(current.get("subscription_active"))
            and isinstance(current_expiry, datetime)
            and current_expiry > _utcnow()
        )
        current_hash = str(current.get("subscription_token_hash") or "")
        new_hash = token_hash(purchase_token)
        replace_current = (
            not current_hash
            or current_hash == new_hash
            or not current_active
            or active
            or (isinstance(current_expiry, datetime) and expiry >= current_expiry)
        )
        transaction.set(
            purchase_ref,
            {
                "uid": uid,
                "product_id": product_id,
                "product_type": "subs",
                "order_id": order_id,
                "subscription_state": state,
                "subscription_expiry": expiry,
                "verified_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        if replace_current:
            cycle_key = str(order_id or "").strip() or f"{new_hash}:{expiry.isoformat()}"
            allowance_update = _plus_allowance_update(current, active, cycle_key)
            entitlement_update = {
                "subscription_active": active,
                "subscription_expiry": expiry,
                "subscription_state": state,
                "subscription_product_id": product_id,
                "subscription_purchase_token": purchase_token,
                "subscription_token_hash": new_hash,
                "updated_at": firestore.SERVER_TIMESTAMP,
            }
            entitlement_update.update(allowance_update)
            transaction.set(
                entitlement_ref,
                entitlement_update,
                merge=True,
            )
            current.update({"subscription_active": active, "subscription_expiry": expiry})
            current.update(allowance_update)
        return _public_entitlement(current)

    return apply(transaction)


def mark_subscription_acknowledged(purchase_token: str) -> None:
    db().collection(PURCHASES).document(token_hash(purchase_token)).set(
        {"acknowledged": True, "acknowledged_at": firestore.SERVER_TIMESTAMP}, merge=True
    )


def _partner_claim_key(uid: str, claim_id: str) -> str:
    return hashlib.sha256(f"{uid}:{claim_id}".encode("utf-8")).hexdigest()


def claim_partner_analysis(uid: str, claim_id: str, *, reward_only: bool = False) -> tuple[bool, dict[str, Any]]:
    """Idempotently authorize one relationship reading.

    The default order is Plus, earned reward, then one-time purchase.
    An explicit reward claim spends from the shared reward balance.
    Repeating the same claim_id never consumes twice.
    """
    client = db()
    entitlement_ref = client.collection(ENTITLEMENTS).document(uid)
    claim_key = _partner_claim_key(uid, claim_id)
    claim_ref = client.collection(PARTNER_CLAIMS).document(claim_key)
    transaction = client.transaction()

    @firestore.transactional
    def apply(transaction):
        claim_snap = claim_ref.get(transaction=transaction)
        entitlement_snap = entitlement_ref.get(transaction=transaction)
        entitlement = entitlement_snap.to_dict() if entitlement_snap.exists else {}
        public = _public_entitlement(entitlement)
        if claim_snap.exists:
            old = claim_snap.to_dict() or {}
            if old.get("uid") != uid:
                raise EntitlementError("partner_claim_collision", 409)
            return bool(old.get("credit_consumed")), public

        consumed = True
        credit_source = _select_credit_source(
            public,
            "partner_credits",
            "partner",
            "partner_entitlement_required",
            reward_only=reward_only,
        )
        field = _credit_field(entitlement, credit_source, "partner_credits")
        remaining = max(0, int(entitlement.get(field) or 0) - 1)
        transaction.set(entitlement_ref, {field: remaining, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True)
        entitlement = {**entitlement, field: remaining}

        public = _public_entitlement(entitlement)

        transaction.create(
            claim_ref,
            {
                "uid": uid,
                "claim_id_hash": hashlib.sha256(claim_id.encode("utf-8")).hexdigest(),
                "credit_consumed": consumed,
                "credit_source": credit_source,
                "subscription_access": public["subscription_active"],
                "plus_allowance_cycle": entitlement.get(field.replace("credits_remaining", "allowance_cycle")) if credit_source == "plus" else None,
                "created_at": firestore.SERVER_TIMESTAMP,
            },
        )
        return consumed, public

    return apply(transaction)


def reserve_partner_ai(uid: str, claim_id: str) -> dict[str, Any]:
    """Use the existing paid claim as the authorization and generation key."""
    client = db()
    report_id = _partner_claim_key(uid, claim_id)
    ref = client.collection(PARTNER_CLAIMS).document(report_id)
    lease = uuid4().hex

    @firestore.transactional
    def apply(transaction):
        snapshot = ref.get(transaction=transaction)
        claim = (snapshot.to_dict() or {}) if snapshot.exists else {}
        if claim.get("uid") != uid:
            raise EntitlementError("partner_claim_required", 403)
        status = claim.get("relationship_ai_status")
        reading = claim.get("relationship_ai_reading")
        if status == "completed" and isinstance(reading, dict):
            return {"report_id": report_id, "cached": reading}
        started = claim.get("relationship_ai_started_at")
        if status == "pending" and isinstance(started, datetime) and started > _utcnow() - timedelta(minutes=3):
            raise EntitlementError("partner_ai_in_progress", 409)
        # Failed runs under the old generation policy get a fresh attempt budget.
        attempts = 0
        if claim.get("relationship_ai_policy") == RELATIONSHIP_AI_POLICY:
            attempts = int(claim.get("relationship_ai_attempts") or 0)
        if attempts >= 3:
            raise EntitlementError("partner_ai_retry_limit", 409)
        transaction.set(ref, {
            "relationship_ai_status": "pending",
            "relationship_ai_started_at": firestore.SERVER_TIMESTAMP,
            "relationship_ai_attempts": attempts + 1,
            "relationship_ai_policy": RELATIONSHIP_AI_POLICY,
            "relationship_ai_lease": lease,
        }, merge=True)
        return {"report_id": report_id, "lease": lease}

    return apply(client.transaction())


def finish_partner_ai(uid: str, report_id: str, lease: str, reading: dict[str, Any] | None) -> bool:
    client = db()
    ref = client.collection(PARTNER_CLAIMS).document(report_id)

    @firestore.transactional
    def apply(transaction):
        snapshot = ref.get(transaction=transaction)
        claim = (snapshot.to_dict() or {}) if snapshot.exists else {}
        if (claim.get("uid") != uid or claim.get("relationship_ai_status") != "pending"
                or claim.get("relationship_ai_lease") != lease):
            return False
        transaction.set(ref, {
            "relationship_ai_status": "completed" if reading is not None else "failed",
            "relationship_ai_reading": reading,
            "relationship_ai_lease": None,
        }, merge=True)
        return True

    return apply(client.transaction())


def reserve_report(
    uid: str, report_id: str, context: dict[str, Any] | None = None, *, reward_only: bool = False
) -> dict[str, Any]:
    client = db()
    entitlement_ref = client.collection(ENTITLEMENTS).document(uid)
    report_ref = client.collection(REPORTS).document(report_id)
    transaction = client.transaction()

    @firestore.transactional
    def apply(transaction):
        report_snap = report_ref.get(transaction=transaction)
        if report_snap.exists:
            old = report_snap.to_dict() or {}
            if old.get("uid") != uid:
                raise EntitlementError("report_id_collision", 409)
            if old.get("status") == "completed" and isinstance(old.get("reading"), dict):
                # Reopening an already-owned report must never consume another
                # credit. Keep a stable pointer so the app can restore it after
                # process death, an app update, or a sign-in on another device.
                transaction.set(
                    entitlement_ref,
                    {"latest_report_id": report_id, "updated_at": firestore.SERVER_TIMESTAMP},
                    merge=True,
                )
                if context and not isinstance(old.get("context"), dict):
                    transaction.set(report_ref, {"context": context}, merge=True)
                return {"cached": old["reading"], "charged_credit": False}
            created = old.get("created_at")
            if old.get("status") == "pending" and isinstance(created, datetime) and created > _utcnow() - timedelta(minutes=3):
                raise EntitlementError("report_generation_in_progress", 409)
            reserved_source = str(old.get("charged_source") or ("report" if old.get("charged_credit") else ""))
            if old.get("status") == "pending" and reserved_source in {"plus", "reward", "report"}:
                # A worker that stopped mid-request already reserved this
                # report's credit. Retrying the same report reuses that charge.
                transaction.set(report_ref, {
                    "created_at": firestore.SERVER_TIMESTAMP,
                    "updated_at": firestore.SERVER_TIMESTAMP,
                }, merge=True)
                return {"cached": None, "charged_credit": True, "charged_source": reserved_source}
        entitlement_snap = entitlement_ref.get(transaction=transaction)
        entitlement = entitlement_snap.to_dict() if entitlement_snap.exists else {}
        public = _public_entitlement(entitlement)
        charged_source = _select_credit_source(
            public,
            "report_credits",
            "report",
            "premium_entitlement_required",
            reward_only=reward_only,
        )
        field = _credit_field(entitlement, charged_source, "report_credits")
        remaining = max(0, int(entitlement.get(field) or 0) - 1)
        transaction.set(entitlement_ref, {field: remaining, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True)
        report_update = {
            "uid": uid,
            "status": "pending",
            "charged_source": charged_source,
            "charged_credit_field": field,
            "charged_credit": charged_source == "report",
            "charged_plus": charged_source == "plus",
            "subscription_access": public["subscription_active"],
            "created_at": firestore.SERVER_TIMESTAMP,
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if charged_source == "plus":
            report_update["plus_allowance_cycle"] = entitlement.get(field.replace("credits_remaining", "allowance_cycle"))
        transaction.set(
            report_ref,
            report_update,
        )
        return {"cached": None, "charged_credit": True, "charged_source": charged_source}

    return apply(transaction)


def complete_report(
    uid: str,
    report_id: str,
    reading: dict[str, Any],
    context: dict[str, Any],
) -> None:
    client = db()
    ref = client.collection(REPORTS).document(report_id)
    snap = ref.get()
    if not snap.exists or (snap.to_dict() or {}).get("uid") != uid:
        raise EntitlementError("report_reservation_missing", 409)
    batch = client.batch()
    batch.set(
        ref,
        {
            "status": "completed",
            "reading": reading,
            "context": context,
            "updated_at": firestore.SERVER_TIMESTAMP,
            "completed_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )
    batch.set(
        client.collection(ENTITLEMENTS).document(uid),
        {"latest_report_id": report_id, "updated_at": firestore.SERVER_TIMESTAMP},
        merge=True,
    )
    batch.commit()


def _iso(value: Any) -> str | None:
    if not isinstance(value, datetime):
        return None
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _saved_report_payload(report_id: str, data: dict[str, Any]) -> dict[str, Any] | None:
    reading = data.get("reading")
    if data.get("status") != "completed" or not isinstance(reading, dict):
        return None
    context = data.get("context") if isinstance(data.get("context"), dict) else {}
    return {
        "report_id": report_id,
        "language": str(context.get("language") or "tr"),
        "reading": reading,
        "context": context,
        "completed_at": _iso(data.get("completed_at") or data.get("updated_at")),
    }


def get_latest_completed_report(uid: str) -> dict[str, Any] | None:
    """Return the user's latest completed report without creating or charging one."""
    client = db()
    entitlement_ref = client.collection(ENTITLEMENTS).document(uid)
    entitlement_snap = entitlement_ref.get()
    entitlement = entitlement_snap.to_dict() if entitlement_snap.exists else {}
    report_id = str((entitlement or {}).get("latest_report_id") or "")
    if report_id:
        snap = client.collection(REPORTS).document(report_id).get()
        data = snap.to_dict() if snap.exists else {}
        if (data or {}).get("uid") == uid:
            payload = _saved_report_payload(report_id, data or {})
            if payload is not None:
                return payload

    # Migration fallback for reports completed before latest_report_id existed.
    candidates: list[tuple[datetime, str, dict[str, Any]]] = []
    for snap in client.collection(REPORTS).where("uid", "==", uid).stream():
        data = snap.to_dict() or {}
        payload = _saved_report_payload(snap.id, data)
        if payload is None:
            continue
        stamp = data.get("completed_at") or data.get("updated_at")
        if not isinstance(stamp, datetime):
            stamp = datetime.min.replace(tzinfo=timezone.utc)
        candidates.append((stamp, snap.id, payload))
    if not candidates:
        return None
    _stamp, report_id, payload = max(candidates, key=lambda item: item[0])
    entitlement_ref.set(
        {"latest_report_id": report_id, "updated_at": firestore.SERVER_TIMESTAMP},
        merge=True,
    )
    return payload


def save_content_report(uid: str, report_id: str, reason: str, client_version: str) -> None:
    """Store an authenticated safety flag without copying generated text."""
    client = db()
    source_ref = client.collection(REPORTS).document(report_id)
    source = source_ref.get()
    source_data = source.to_dict() if source.exists else {}
    content_type = "ai_reading"
    if (source_data or {}).get("uid") != uid or (source_data or {}).get("status") != "completed":
        claim = client.collection(PARTNER_CLAIMS).document(report_id).get()
        claim_data = (claim.to_dict() or {}) if claim.exists else {}
        if claim_data.get("uid") != uid or claim_data.get("relationship_ai_status") != "completed":
            raise EntitlementError("report_not_found", 404)
        content_type = "relationship_ai_reading"

    flag_id = hashlib.sha256(f"{uid}:{report_id}".encode("utf-8")).hexdigest()
    client.collection(CONTENT_REPORTS).document(flag_id).set(
        {
            "uid": uid,
            "report_id": report_id,
            "content_type": content_type,
            "reason": reason,
            "client_version": client_version[:64],
            "updated_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )


def _feedback_id(uid: str, report_id: str) -> str:
    return hashlib.sha256(f"{uid}:{report_id}".encode("utf-8")).hexdigest()


def _owned_completed_report(source: Any, uid: str) -> dict:
    data = source.to_dict() if source.exists else {}
    if not isinstance(data, dict) or data.get("uid") != uid or data.get("status") != "completed":
        raise EntitlementError("report_not_found", 404)
    return data


def save_reading_feedback(uid: str, feedback: dict, client_version: str) -> None:
    """One editable response per owned report; retries never create extra votes."""
    client = db()
    identifier = feedback["report_id"]
    source = client.collection(REPORTS).document(identifier)
    target = client.collection(READING_FEEDBACK).document(_feedback_id(uid, identifier))

    @firestore.transactional
    def apply(tx):
        report = _owned_completed_report(source.get(transaction=tx), uid)
        previous = target.get(transaction=tx)
        old = (previous.to_dict() or {}) if previous.exists else {}
        # Only the explicit, bounded feedback fields are stored. No report
        # text, photo, name, date, or caller-supplied policy is copied.
        values = {key: feedback[key] for key in ("rating", "suggestion", "language")}
        if previous.exists and all(old.get(key) == value for key, value in values.items()):
            return
        if isinstance(old.get("updated_at"), datetime) and old["updated_at"] > _utcnow() - timedelta(seconds=5):
            raise EntitlementError("feedback_too_fast", 429)
        reading = report.get("reading") or {}
        policy = reading.get("ai_policy") if isinstance(reading, dict) else None
        values.update({"uid": uid, "report_id": identifier, "client_version": client_version[:64],
                       "ai_policy": str(policy or "legacy_or_unknown")[:96],
                       "updated_at": firestore.SERVER_TIMESTAMP})
        if not previous.exists:
            values["created_at"] = firestore.SERVER_TIMESTAMP
        tx.set(target, values, merge=True)

    apply(client.transaction())


def get_reading_feedback(uid: str, report_id: str) -> dict | None:
    client = db()
    _owned_completed_report(client.collection(REPORTS).document(report_id).get(), uid)
    snapshot = client.collection(READING_FEEDBACK).document(_feedback_id(uid, report_id)).get()
    if not snapshot.exists:
        return None
    data = snapshot.to_dict() or {}
    return {key: data.get(key) for key in ("rating", "suggestion", "language")}


def fail_report(uid: str, report_id: str) -> None:
    client = db()
    entitlement_ref = client.collection(ENTITLEMENTS).document(uid)
    report_ref = client.collection(REPORTS).document(report_id)
    transaction = client.transaction()

    @firestore.transactional
    def apply(transaction):
        snap = report_ref.get(transaction=transaction)
        if not snap.exists:
            return
        data = snap.to_dict() or {}
        if data.get("uid") != uid or data.get("status") != "pending":
            return
        charged_source = str(data.get("charged_source") or ("report" if data.get("charged_credit") else ""))
        if charged_source:
            ent_snap = entitlement_ref.get(transaction=transaction)
            ent = ent_snap.to_dict() if ent_snap.exists else {}
            field = data.get("charged_credit_field")
            if charged_source == "plus":
                field = field if field == "apple_plus_credits_remaining" else "plus_credits_remaining"
                cycle_field = field.replace("credits_remaining", "allowance_cycle")
                if data.get("plus_allowance_cycle") == ent.get(cycle_field):
                    remaining = min(PLUS_MONTHLY_CREDITS, max(0, int(ent.get(field) or 0)) + 1)
                    transaction.set(entitlement_ref, {field: remaining, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True)
            elif charged_source == "report":
                field = field if field == "apple_report_credits" else "report_credits"
                credits = max(0, int(ent.get(field) or 0)) + 1
                if field == "report_credits":
                    credits = min(MAX_REPORT_CREDITS, credits)
                transaction.set(entitlement_ref, {field: credits, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True)
            elif charged_source == "reward":
                credits = min(100, max(0, int(ent.get("reward_credits") or 0)) + 1)
                transaction.set(entitlement_ref, {"reward_credits": credits, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True)
        transaction.set(
            report_ref,
            {
                "status": "failed",
                "charged_source": "",
                "charged_credit": False,
                "charged_plus": False,
                "updated_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )

    apply(transaction)


def delete_account_data(uid: str) -> dict[str, int]:
    """Delete user-owned PalmMap data while retaining only anti-replay receipts.

    Purchase documents are keyed by a hash of the Google Play purchase token.
    They are stripped of account and order identifiers instead of being removed,
    so a consumed purchase cannot be attached to a newly created account later.
    """
    client = db()
    report_refs = [snap.reference for snap in client.collection(REPORTS).where("uid", "==", uid).stream()]
    legacy_refs = [snap.reference for snap in client.collection(LEGACY_PREVIEWS).where("uid", "==", uid).stream()]
    purchase_refs = [snap.reference for snap in client.collection(PURCHASES).where("uid", "==", uid).stream()]
    partner_claim_refs = [snap.reference for snap in client.collection(PARTNER_CLAIMS).where("uid", "==", uid).stream()]
    content_report_refs = [snap.reference for snap in client.collection(CONTENT_REPORTS).where("uid", "==", uid).stream()]
    feedback_refs = [snap.reference for snap in client.collection(READING_FEEDBACK).where("uid", "==", uid).stream()]
    ad_session_refs = [snap.reference for snap in client.collection("palmmap_ad_sessions").where("uid", "==", uid).stream()]
    ad_limit_refs = [snap.reference for snap in client.collection("palmmap_ad_daily_limits").where("uid", "==", uid).stream()]

    operations: list[tuple[str, Any]] = []
    operations.extend(("delete", ref) for ref in report_refs)
    operations.extend(("delete", ref) for ref in legacy_refs)
    operations.extend(("delete", ref) for ref in partner_claim_refs)
    operations.extend(("delete", ref) for ref in content_report_refs)
    operations.extend(("delete", ref) for ref in feedback_refs)
    operations.extend(("delete", ref) for ref in ad_limit_refs)
    operations.extend(("anonymize_ad", ref) for ref in ad_session_refs)
    operations.append(("delete", client.collection(ENTITLEMENTS).document(uid)))
    operations.extend(("anonymize_purchase", ref) for ref in purchase_refs)

    for start in range(0, len(operations), 450):
        batch = client.batch()
        for action, ref in operations[start : start + 450]:
            if action == "delete":
                batch.delete(ref)
            elif action == "anonymize_ad":
                batch.set(ref, {"uid": firestore.DELETE_FIELD, "account_deleted": True,
                               "account_deleted_at": firestore.SERVER_TIMESTAMP}, merge=True)
            else:
                batch.set(
                    ref,
                    {
                        "uid": firestore.DELETE_FIELD,
                        "order_id": firestore.DELETE_FIELD,
                        "subscription_state": firestore.DELETE_FIELD,
                        "subscription_expiry": firestore.DELETE_FIELD,
                        "account_deleted": True,
                        "account_deleted_at": firestore.SERVER_TIMESTAMP,
                    },
                    merge=True,
                )
        batch.commit()

    return {
        "reports_deleted": len(report_refs),
        "legacy_previews_deleted": len(legacy_refs),
        "partner_claims_deleted": len(partner_claim_refs),
        "content_reports_deleted": len(content_report_refs),
        "reading_feedback_deleted": len(feedback_refs),
        "purchase_receipts_anonymized": len(purchase_refs),
    }
