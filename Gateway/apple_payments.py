"""Verify signed App Store transactions and notifications using Apple's library."""
from __future__ import annotations

from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from uuid import UUID, uuid5
import re

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.NotificationTypeV2 import NotificationTypeV2
from appstoreserverlibrary.models.Status import Status
from appstoreserverlibrary.models.Type import Type
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier, VerificationException, VerificationStatus

import apple_entitlements
import config
import store

ACCOUNT_NAMESPACE = UUID("79ba56e3-b51a-49dd-9b97-8e9eb55b8462")
TRANSACTION_ID = re.compile(r"[0-9]{1,32}")


def account_token(uid: str) -> str:
    return str(uuid5(ACCOUNT_NAMESPACE, uid))


def _enabled() -> None:
    if not config.APPLE_STORE_ENABLED:
        raise store.EntitlementError("ios_store_not_configured", 503)


@lru_cache(maxsize=2)
def _verifier(environment: Environment) -> SignedDataVerifier:
    directory = Path(config.APPLE_ROOT_CERTS_DIR)
    roots = [path.read_bytes() for path in sorted(directory.glob("*.cer")) if path.is_file()]
    if not roots or not config.APPLE_APP_ID:
        raise store.EntitlementError("ios_store_not_configured", 503)
    return SignedDataVerifier(roots, True, environment, config.APPLE_BUNDLE_ID,
                              config.APPLE_APP_ID if environment == Environment.PRODUCTION else None)


def _jws(value: object) -> str:
    if not isinstance(value, str) or not 20 <= len(value) <= 48_000 or value.count(".") != 2:
        raise store.EntitlementError("invalid_apple_signature", 400)
    return value


def _verify(value: object, notification: bool = False):
    signed = _jws(value)
    retryable = False
    environments = [Environment.PRODUCTION]
    if config.APPLE_SANDBOX_UIDS:
        environments.append(Environment.SANDBOX)
    for environment in environments:
        verifier = _verifier(environment)
        decode = (verifier.verify_and_decode_notification if notification
                  else verifier.verify_and_decode_signed_transaction)
        try:
            return environment, decode(signed)
        except VerificationException as exc:
            retryable = retryable or exc.status == VerificationStatus.RETRYABLE_VERIFICATION_FAILURE
    if retryable:
        raise store.EntitlementError("apple_verification_temporarily_unavailable", 503)
    raise store.EntitlementError("invalid_apple_signature", 400)


def _date(ms: int | None) -> datetime:
    if not isinstance(ms, int) or ms <= 0:
        raise store.EntitlementError("invalid_apple_transaction", 400)
    try:
        return datetime.fromtimestamp(ms / 1000, tz=timezone.utc)
    except (OverflowError, ValueError, OSError) as exc:
        raise store.EntitlementError("invalid_apple_transaction", 400) from exc


def _receipt(environment: Environment, tx, *, event_ms: int | None = None,
             status: Status | None = None, grace_expiry: int | None = None,
             refund_reversed: bool = False) -> apple_entitlements.Receipt:
    identifier, original = tx.transactionId or "", tx.originalTransactionId or ""
    if not TRANSACTION_ID.fullmatch(identifier) or not TRANSACTION_ID.fullmatch(original):
        raise store.EntitlementError("invalid_apple_transaction", 400)
    sku = tx.productId
    subscription = sku == config.SUBSCRIPTION_PRODUCT_ID
    expected = Type.AUTO_RENEWABLE_SUBSCRIPTION if subscription else Type.CONSUMABLE
    if sku not in (config.INAPP_PRODUCT_IDS | {config.SUBSCRIPTION_PRODUCT_ID}) or tx.type != expected:
        raise store.EntitlementError("wrong_product", 400)
    _date(tx.purchaseDate)
    _date(event_ms or tx.signedDate)
    revoked = tx.revocationDate is not None or status == Status.REVOKED
    expiry = _date(tx.expiresDate) if subscription else None
    if subscription and status == Status.BILLING_GRACE_PERIOD and grace_expiry:
        expiry = max(expiry, _date(grace_expiry))
    inactive = status in {Status.EXPIRED, Status.BILLING_RETRY, Status.REVOKED} or bool(tx.isUpgraded)
    quantity = tx.quantity or 1
    if not isinstance(quantity, int) or not 1 <= quantity <= 10 or (subscription and quantity != 1):
        raise store.EntitlementError("invalid_apple_quantity", 400)
    return apple_entitlements.Receipt(
        environment=environment.value, identifier=identifier, original=original,
        product=sku, subscription=subscription, quantity=quantity, purchase_ms=tx.purchaseDate,
        event_ms=event_ms or tx.signedDate, expiry=expiry,
        revoked=revoked and not refund_reversed, inactive=inactive, refund_reversed=refund_reversed,
    )


def _check_owner(uid: str, environment: Environment, token: str | None) -> None:
    if environment == Environment.SANDBOX and uid not in config.APPLE_SANDBOX_UIDS:
        raise store.EntitlementError("apple_sandbox_not_enabled_for_account", 403)
    if not token or token.lower() != account_token(uid):
        raise store.EntitlementError("apple_transaction_account_mismatch", 409)


def verify_purchase(uid: str, value: object) -> tuple[bool, dict]:
    _enabled()
    environment, tx = _verify(value)
    _check_owner(uid, environment, tx.appAccountToken)
    return apple_entitlements.record(uid, _receipt(environment, tx))


def notification(value: object) -> None:
    _enabled()
    environment, message = _verify(value, notification=True)
    data = message.data
    if not data or not data.signedTransactionInfo:
        return
    verifier = _verifier(environment)
    try:
        tx = verifier.verify_and_decode_signed_transaction(data.signedTransactionInfo)
        renewal = (verifier.verify_and_decode_renewal_info(data.signedRenewalInfo)
                   if data.signedRenewalInfo and data.status == Status.BILLING_GRACE_PERIOD else None)
    except VerificationException as exc:
        code = 503 if exc.status == VerificationStatus.RETRYABLE_VERIFICATION_FAILURE else 400
        raise store.EntitlementError("invalid_apple_notification_transaction", code) from exc
    if tx.productId not in (config.INAPP_PRODUCT_IDS | {config.SUBSCRIPTION_PRODUCT_ID}):
        return
    receipt = _receipt(environment, tx, event_ms=message.signedDate, status=data.status,
                       grace_expiry=renewal.gracePeriodExpiresDate if renewal else None,
                       refund_reversed=message.notificationType == NotificationTypeV2.REFUND_REVERSED)
    uid = apple_entitlements.owner(receipt)
    if uid:
        if tx.appAccountToken:
            _check_owner(uid, environment, tx.appAccountToken)
        elif environment == Environment.SANDBOX and uid not in config.APPLE_SANDBOX_UIDS:
            return
        apple_entitlements.record(uid, receipt, from_notification=True)
    elif receipt.revoked and environment == Environment.PRODUCTION and not receipt.subscription:
        apple_entitlements.record(None, receipt, from_notification=True)
