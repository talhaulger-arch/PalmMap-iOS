"""Apply verified App Store receipts atomically to the existing PalmMap wallet."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from google.cloud import firestore

import config
import store


@dataclass(frozen=True)
class Receipt:
    environment: str
    identifier: str
    original: str
    product: str
    subscription: bool
    quantity: int
    purchase_ms: int
    event_ms: int
    expiry: datetime | None
    revoked: bool
    inactive: bool
    refund_reversed: bool

    @property
    def key(self) -> str:
        number = self.original if self.subscription else self.identifier
        return store.token_hash(f"apple:{self.environment}:{number}")


def _receipt_ref(client, receipt: Receipt):
    return client.collection(store.PURCHASES).document(receipt.key)


def owner(receipt: Receipt) -> str | None:
    snapshot = _receipt_ref(store.db(), receipt).get()
    return (snapshot.to_dict() or {}).get("uid") if snapshot.exists else None


def _current_or_reversed(previous: dict, receipt: Receipt) -> bool:
    if previous.get("apple_revoked") and not receipt.revoked and not receipt.refund_reversed:
        return False
    return receipt.event_ms >= int(previous.get("apple_event_ms") or 0)


def record(uid: str | None, receipt: Receipt, *, from_notification: bool = False) -> tuple[bool, dict]:
    client = store.db()
    purchase = _receipt_ref(client, receipt)
    entitlement = client.collection(store.ENTITLEMENTS).document(uid) if uid else None

    @firestore.transactional
    def apply(tx):
        previous = purchase.get(transaction=tx).to_dict() or {}
        if previous.get("account_deleted"):
            if from_notification:
                return False, {}
            raise store.EntitlementError("purchase_token_already_claimed", 409)
        if previous.get("uid") and previous["uid"] != uid:
            if from_notification:
                return False, {}
            raise store.EntitlementError("purchase_token_already_claimed", 409)
        if uid is None:
            if not previous and receipt.revoked and not receipt.subscription:
                tx.create(purchase, {"apple_revoked": True, "apple_event_ms": receipt.event_ms,
                                     "product_id": receipt.product, "source": "apple"})
            return False, {}
        if from_notification and not previous.get("uid"):
            return False, {}

        current = entitlement.get(transaction=tx).to_dict() or {}
        if previous.get("product_id") and previous["product_id"] != receipt.product:
            raise store.EntitlementError("wrong_product", 409)

        update: dict = {}
        receipt_fields = {
            "uid": uid,
            "product_id": receipt.product,
            "product_type": "subs" if receipt.subscription else "inapp",
            "source": "apple",
            "settled": True,
            "apple_event_ms": receipt.event_ms,
            "apple_revoked": receipt.revoked,
            "verified_at": firestore.SERVER_TIMESTAMP,
        }
        grant = False
        if receipt.subscription:
            if not _subscription_update(previous, current, receipt, receipt_fields, update, from_notification):
                return False, store._public_entitlement(current)
        else:
            if not _current_or_reversed(previous, receipt):
                return False, store._public_entitlement(current)
            field = ("apple_report_credits" if receipt.product == config.INAPP_PRODUCT_ID
                     else "apple_partner_credits")
            active = bool(previous.get("apple_credit_granted")) and not previous.get("apple_revoked")
            amount = max(0, int(current.get(field) or 0))
            previous_quantity = int(previous.get("apple_quantity") or 0)
            if receipt.revoked and active:
                update[field] = max(0, amount - previous_quantity)
            elif not receipt.revoked and not active:
                update[field] = amount + receipt.quantity
                grant = True
            receipt_fields["apple_credit_granted"] = (active or grant) and not receipt.revoked
            receipt_fields["apple_quantity"] = receipt.quantity

        if update:
            tx.set(entitlement, {**update, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True)
        tx.set(purchase, receipt_fields, merge=True)
        return grant, store._public_entitlement({**current, **update})

    return apply(client.transaction())


def _subscription_update(previous: dict, current: dict, receipt: Receipt, receipt_fields: dict, update: dict,
                         from_notification: bool) -> bool:
    last_purchase = int(previous.get("apple_purchase_ms") or 0)
    if receipt.purchase_ms < last_purchase:
        return False
    if receipt.purchase_ms == last_purchase and not _current_or_reversed(previous, receipt):
        return False
    last_tx = previous.get("apple_transaction")
    if last_tx == receipt.identifier and not from_notification and not receipt.revoked:
        if (previous.get("apple_expiry") or receipt.expiry) > receipt.expiry:
            return False  # A client receipt may omit a verified billing grace period.
    if last_tx == receipt.identifier and previous.get("apple_inactive") and not receipt.refund_reversed:
        if not receipt.inactive and receipt.expiry <= (previous.get("apple_expiry") or receipt.expiry):
            return False
    receipt_fields.update(
        apple_purchase_ms=receipt.purchase_ms, apple_transaction=receipt.identifier,
        apple_inactive=receipt.inactive, apple_expiry=receipt.expiry,
    )
    active = bool(receipt.expiry and receipt.expiry > store._utcnow() and not receipt.revoked and not receipt.inactive)
    selected = current.get("apple_subscription_key")
    if selected and selected != receipt.key:
        if not active or receipt.purchase_ms < int(current.get("apple_subscription_purchase_ms") or 0):
            return True
    update.update(
        apple_subscription_key=receipt.key,
        apple_subscription_purchase_ms=receipt.purchase_ms,
        apple_subscription_active=active,
        apple_subscription_expiry=receipt.expiry,
    )
    cycle = store.token_hash(f"{receipt.environment}:{receipt.identifier}")
    if active and current.get("apple_plus_allowance_cycle") != cycle:
        update.update(apple_plus_allowance_cycle=cycle, apple_plus_credits_remaining=config.PLUS_MONTHLY_CREDITS)
    return True
