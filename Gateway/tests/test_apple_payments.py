import os
import unittest
from datetime import timedelta
from types import SimpleNamespace
from unittest.mock import patch

os.environ.setdefault("PALMMAP_INTERNAL_BACKEND_URL", "https://palmmap-worker-test.run.app")
os.environ.setdefault("PALMMAP_FIREBASE_WEB_API_KEY", "AIza" + "x" * 35)

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.Status import Status
from appstoreserverlibrary.models.Type import Type

import apple_entitlements as ledger
import apple_payments as apple
import config
import main
import store


class Database:
    def __init__(self):
        self.documents = {}

    def collection(self, name):
        return SimpleNamespace(document=lambda key: Document(self, (name, key)))

    def transaction(self):
        return self

    def set(self, ref, values, merge=False):
        self.documents[ref.key] = {**(self.documents.get(ref.key, {}) if merge else {}), **values}

    def create(self, ref, values):
        if ref.key in self.documents:
            raise AssertionError("Duplicate creation")
        self.set(ref, values)


class Document:
    def __init__(self, db, key):
        self.db = db
        self.key = key

    def get(self, transaction=None):
        values = self.db.documents.get(self.key)
        return SimpleNamespace(exists=values is not None, to_dict=lambda: dict(values) if values else None)


class ApplePaymentsTests(unittest.TestCase):
    def setUp(self):
        self.db = Database()
        self.addCleanup(patch.stopall)
        patch.object(store, "db", return_value=self.db).start()
        patch.object(ledger.firestore, "transactional", side_effect=lambda f: f).start()
        self.now = store._utcnow()
        self.time = int(self.now.timestamp() * 1000)

    def receipt(self, *, subscription=False, revoked=False, inactive=False, reversed_=False, delta=0, identifier="101"):
        return ledger.Receipt(
            environment="Production", identifier=identifier, original="101",
            product=config.SUBSCRIPTION_PRODUCT_ID if subscription else config.INAPP_PRODUCT_ID,
            subscription=subscription, quantity=1,
            purchase_ms=self.time if identifier == "101" else self.time + 10,
            event_ms=self.time + delta,
            expiry=self.now + timedelta(days=30) if subscription else None,
            revoked=revoked, inactive=inactive, refund_reversed=reversed_,
        )

    def test_consumable_replay_is_idempotent_and_uid_bound(self):
        receipt = self.receipt()
        self.assertEqual(ledger.record("one", receipt)[1]["report_credits"], 1)
        self.assertEqual(ledger.record("one", receipt), (False, store.get_entitlement("one")))
        with self.assertRaises(store.EntitlementError):
            ledger.record("two", receipt)

    def test_refund_does_not_remove_google_play_credit(self):
        ref = self.db.collection(store.ENTITLEMENTS).document("one")
        self.db.set(ref, {"report_credits": 2})
        ledger.record("one", self.receipt())
        ledger.record("one", self.receipt(revoked=True, delta=30), from_notification=True)
        self.assertEqual(store.get_entitlement("one")["report_credits"], 2)
        ledger.record("one", self.receipt(delta=40))
        self.assertEqual(store.get_entitlement("one")["report_credits"], 2)
        ledger.record("one", self.receipt(reversed_=True, delta=50), from_notification=True)
        self.assertEqual(store.get_entitlement("one")["report_credits"], 3)

    def test_refund_before_client_verification_prevents_grant(self):
        ledger.record(None, self.receipt(revoked=True, delta=20), from_notification=True)
        self.assertFalse(ledger.record("one", self.receipt())[0])
        self.assertEqual(store.get_entitlement("one")["report_credits"], 0)

    def test_renewal_reloads_plus_once_and_old_event_is_ignored(self):
        initial = self.receipt(subscription=True)
        self.assertEqual(ledger.record("one", initial)[1]["plus_credits_remaining"], 30)
        ref = self.db.collection(store.ENTITLEMENTS).document("one")
        self.db.set(ref, {"apple_plus_credits_remaining": 13}, merge=True)
        self.assertEqual(ledger.record("one", initial)[1]["plus_credits_remaining"], 13)
        renewal = self.receipt(subscription=True, delta=50, identifier="102")
        self.assertEqual(ledger.record("one", renewal, from_notification=True)[1]["plus_credits_remaining"], 30)
        self.assertTrue(ledger.record("one", self.receipt(subscription=True, revoked=True, delta=60),
                                      from_notification=True)[1]["subscription_active"])

    def test_apple_report_reservation_debits_and_restores_apple_balance(self):
        ledger.record("one", self.receipt())
        store.reserve_report("one", "report-id", {})
        self.assertEqual(store.get_entitlement("one")["report_credits"], 0)
        store.fail_report("one", "report-id")
        state = self.db.collection(store.ENTITLEMENTS).document("one").get().to_dict()
        self.assertEqual(state["apple_report_credits"], 1)
        self.assertNotIn("report_credits", state)

    def test_apple_plus_can_be_used_for_relationship(self):
        ledger.record("one", self.receipt(subscription=True))
        consumed, entitlement = store.claim_partner_analysis("one", "stable-claim-0001")
        self.assertTrue(consumed)
        self.assertEqual(entitlement["plus_credits_remaining"], 29)
        self.assertEqual(store.claim_partner_analysis("one", "stable-claim-0001")[1]["plus_credits_remaining"], 29)

    def test_apple_account_binding_and_sandbox_allowlist(self):
        token = apple.account_token("one")
        apple._check_owner("one", Environment.PRODUCTION, token)
        with self.assertRaises(store.EntitlementError):
            apple._check_owner("two", Environment.PRODUCTION, token)
        with self.assertRaises(store.EntitlementError):
            apple._check_owner("one", Environment.SANDBOX, token)

    def test_apple_receipt_enforces_type_and_status(self):
        tx = SimpleNamespace(transactionId="42", originalTransactionId="42", productId=config.SUBSCRIPTION_PRODUCT_ID,
            type=Type.AUTO_RENEWABLE_SUBSCRIPTION, purchaseDate=self.time, signedDate=self.time,
            expiresDate=self.time + 30_000, revocationDate=None, isUpgraded=False, quantity=1)
        self.assertTrue(apple._receipt(Environment.PRODUCTION, tx, status=Status.BILLING_RETRY).inactive)
        tx.type = Type.CONSUMABLE
        with self.assertRaises(store.EntitlementError):
            apple._receipt(Environment.PRODUCTION, tx)

    def test_verification_route_requires_a_firebase_session(self):
        response = main.app.test_client().post("/v1/ios/purchases/verify", json={"signed_transaction":"fake"})
        self.assertEqual(response.status_code, 401)

    def test_apple_webhook_rejects_unsigned_payload(self):
        with patch.object(config, "APPLE_STORE_ENABLED", True):
            response = main.app.test_client().post("/apple/notifications", json={"signedPayload":"fake"})
        self.assertEqual(response.status_code, 400)


if __name__ == "__main__":
    unittest.main()
