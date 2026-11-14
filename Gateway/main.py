"""Public PalmMap API gateway.

Cloud Run IAM permits public network access to this service, while every /v1
route enforces a fresh Firebase ID token. Paid state is decided only here after
Google Play verification and persisted in server-only Firestore collections.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from typing import Any

from flask import Flask, Response, g, jsonify, render_template, request
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2 import id_token
import requests
from werkzeug.exceptions import HTTPException

import apple_payments
import config
import play_api
import store
import rewards
import reading_feedback
from security import AuthError, assert_source_safe, delete_firebase_user, verify_bearer


config.validate()
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = config.MAX_BODY_BYTES
logging.getLogger("werkzeug").setLevel(logging.WARNING)


class ApiError(Exception):
    def __init__(self, code: str, status: int = 400):
        super().__init__(code)
        self.code = code
        self.status = status


def _response(payload: dict[str, Any], status: int = 200) -> tuple[Response, int]:
    response = jsonify(payload)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response, status


def _body() -> dict[str, Any]:
    if request.content_length is None or request.content_length <= 0:
        raise ApiError("missing_json_body")
    if request.content_length > config.MAX_BODY_BYTES:
        raise ApiError("request_too_large", 413)
    value = request.get_json(silent=True)
    if not isinstance(value, dict):
        raise ApiError("invalid_json_body")
    return value


@app.after_request
def add_security_headers(response: Response) -> Response:
    """Apply browser-safe defaults to API and public legal pages."""
    response.headers.setdefault("Cache-Control", "no-store")
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response


@app.before_request
def authenticate() -> None:
    if request.path == "/health":
        return
    if not request.path.startswith("/v1/"):
        return
    try:
        g.firebase = verify_bearer(request.headers.get("Authorization"))
    except AuthError as exc:
        raise ApiError(str(exc), 401) from exc


@app.errorhandler(ApiError)
def api_error(exc: ApiError):
    return _response({"error": exc.code}, exc.status)


@app.errorhandler(play_api.PlayError)
def play_error(exc: play_api.PlayError):
    return _response({"error": exc.code}, exc.status)


@app.errorhandler(store.EntitlementError)
def entitlement_error(exc: store.EntitlementError):
    return _response({"error": exc.code}, exc.status)


@app.errorhandler(413)
def too_large(_exc):
    return _response({"error": "request_too_large"}, 413)


@app.errorhandler(HTTPException)
def http_error(exc: HTTPException):
    code = int(exc.code or 500)
    return _response({"error": "not_found" if code == 404 else "http_error"}, code)


@app.errorhandler(Exception)
def unexpected(exc: Exception):
    app.logger.exception("PalmMap API request failed: %s", type(exc).__name__)
    return _response({"error": "service_unavailable"}, 503)


@app.get("/health")
def health():
    return _response({"ok": True, "service": "palmmap-api", "version": 17, "ai_policy": config.REPORT_PIPELINE_VERSION,
                      "relationship_ai_policy": config.RELATIONSHIP_AI_POLICY,
                      "features": ["reading_feedback_v1", "near_term_outlook_v2", "relationship_ai_v1", "shared_reward_claims_v1"]})


@app.get("/privacy")
def privacy_policy():
    return render_template("privacy.html", support_email=config.SUPPORT_EMAIL)


@app.get("/delete-account")
def delete_account_page():
    return render_template(
        "delete_account.html",
        support_email=config.SUPPORT_EMAIL,
        firebase_web_api_key=config.FIREBASE_WEB_API_KEY,
    )


@app.get("/v1/entitlements")
def entitlements():
    uid = g.firebase["uid"]
    _refresh_saved_subscription(uid)
    return _response({"entitlement": store.get_entitlement(uid)})


@app.get("/v1/reports/latest")
def latest_report():
    """Restore an already-generated report; this route never reserves credit."""
    uid = g.firebase["uid"]
    return _response({"report": store.get_latest_completed_report(uid)})


def _require_reward_attestation(expected_app_id: str = "") -> None:
    if not config.REWARD_REQUIRE_APP_CHECK and not expected_app_id:
        return
    from firebase_admin import app_check
    try:
        token = request.headers.get("X-Firebase-AppCheck", "")
        if not token:
            raise ValueError("missing_app_check")
        claims = app_check.verify_token(token)
        if expected_app_id and claims.get("sub") != expected_app_id:
            raise ValueError("wrong_firebase_app")
    except Exception as exc:
        raise ApiError("reward_device_verification_required", 403) from exc


@app.get("/v1/rewards/wallet")
def reward_wallet():
    return _response(rewards.wallet(g.firebase["uid"]))


@app.post("/v1/rewards/session")
def reward_session():
    _require_reward_attestation()
    return _response(rewards.begin(g.firebase["uid"]))


@app.post("/v1/ios/rewards/session")
def ios_reward_session():
    if not config.IOS_REWARDED_AD_UNIT or not config.IOS_FIREBASE_APP_ID:
        raise ApiError("rewards_not_configured", 503)
    _require_reward_attestation(config.IOS_FIREBASE_APP_ID)
    return _response(rewards.begin(g.firebase["uid"], ad_unit=config.IOS_REWARDED_AD_UNIT))


@app.post("/v1/rewards/revenue")
def reward_revenue():
    _require_reward_attestation()
    return _response(rewards.record_revenue(g.firebase["uid"], _body()))


@app.get("/admob/ssv")
def reward_ssv():
    # Google callbacks have no Firebase session. Only the raw ECDSA signature
    # authorizes this route; the app's completion callback cannot grant credits.
    try:
        params = rewards.verify_ssv(request.query_string)
    except ValueError as exc:
        raise ApiError(str(exc), 400) from exc
    rewards.confirm_ssv(params)
    return _response({"received": True})


@app.post("/v1/content-reports")
def content_report():
    """Accept an in-app safety flag for an owned AI reading without storing its text."""
    uid = g.firebase["uid"]
    body = _body()
    report_id = str(body.get("report_id") or "").strip().lower()
    reason = str(body.get("reason") or "").strip().lower()
    allowed_reasons = {"harmful_or_offensive", "misleading_or_upsetting", "other"}
    if len(report_id) != 64 or any(ch not in "0123456789abcdef" for ch in report_id):
        raise ApiError("invalid_report_id")
    if reason not in allowed_reasons:
        raise ApiError("invalid_report_reason")
    client_version = str(request.headers.get("X-PalmMap-Client") or "")
    store.save_content_report(uid, report_id, reason, client_version)
    return _response({"reported": True})


@app.post("/v1/reading-feedback")
def submit_reading_feedback():
    try:
        feedback = reading_feedback.normalize(_body())
    except ValueError as exc:
        raise ApiError(str(exc)) from exc
    store.save_reading_feedback(g.firebase["uid"], feedback, str(request.headers.get("X-PalmMap-Client") or "")[:64])
    return _response({"saved": True})


@app.get("/v1/reading-feedback")
def get_reading_feedback():
    try:
        identifier = reading_feedback.report_id(request.args.get("report_id"))
    except ValueError as exc:
        raise ApiError(str(exc)) from exc
    return _response({"feedback": store.get_reading_feedback(g.firebase["uid"], identifier)})


@app.delete("/v1/account")
def delete_account():
    """Delete cloud reports, entitlements and the Firebase identity."""
    uid = g.firebase["uid"]
    deleted = store.delete_account_data(uid)
    delete_firebase_user(uid)
    return _response({"deleted": True, "data": deleted})


def _validated_purchase_input() -> tuple[str, str, str]:
    body = _body()
    product_type = str(body.get("product_type") or "")
    product_id = str(body.get("product_id") or "")
    purchase_token = str(body.get("purchase_token") or "")
    if product_type not in {"inapp", "subs"}:
        raise ApiError("invalid_product_type")
    allowed = config.INAPP_PRODUCT_IDS if product_type == "inapp" else {config.SUBSCRIPTION_PRODUCT_ID}
    if product_id not in allowed:
        raise ApiError("wrong_product")
    if not purchase_token or len(purchase_token) > 4096 or any(ch.isspace() for ch in purchase_token):
        raise ApiError("invalid_purchase_token")
    return product_type, product_id, purchase_token


def _save_verified_subscription(uid: str, product_id: str, purchase_token: str) -> dict[str, Any]:
    verified = play_api.verify_subscription(uid, product_id, purchase_token)
    entitlement = store.record_subscription(
        uid,
        purchase_token,
        product_id,
        verified["active"],
        verified["state"],
        verified["expiry"],
        verified["order_id"],
    )
    if verified["acknowledgement_state"] == "ACKNOWLEDGEMENT_STATE_PENDING":
        play_api.acknowledge_subscription(product_id, purchase_token)
        store.mark_subscription_acknowledged(purchase_token)
    return entitlement


def _refresh_saved_subscription(uid: str) -> None:
    saved = store.get_subscription_reference(uid)
    if saved is not None:
        _save_verified_subscription(uid, saved["product_id"], saved["purchase_token"])


@app.post("/v1/purchases/verify")
def verify_purchase():
    uid = g.firebase["uid"]
    product_type, product_id, purchase_token = _validated_purchase_input()
    if product_type == "inapp":
        verified = play_api.verify_consumable(uid, product_id, purchase_token)
        granted, entitlement = store.grant_consumable(
            uid,
            purchase_token,
            product_id,
            verified["quantity"],
            verified["order_id"],
        )
        if verified["consumption_state"] != "CONSUMPTION_STATE_CONSUMED":
            play_api.consume(product_id, purchase_token)
        store.mark_consumed(purchase_token)
        return _response({"verified": True, "new_grant": granted, "entitlement": entitlement})

    entitlement = _save_verified_subscription(uid, product_id, purchase_token)
    return _response({"verified": True, "new_grant": False, "entitlement": entitlement})


@app.get("/v1/ios/store")
def ios_store():
    return _response({
        "enabled": config.APPLE_STORE_ENABLED,
        "app_account_token": apple_payments.account_token(g.firebase["uid"]),
    })


@app.post("/v1/ios/purchases/verify")
def verify_apple_purchase():
    uid = g.firebase["uid"]
    grant, entitlement = apple_payments.verify_purchase(uid, _body().get("signed_transaction"))
    return _response({"verified": True, "new_grant": grant, "entitlement": entitlement})


@app.post("/apple/notifications")
def apple_notifications():
    apple_payments.notification(_body().get("signedPayload"))
    return _response({"received": True})


def _partner_claim_id(value: Any) -> str:
    claim_id = str(value or "")
    if not (16 <= len(claim_id) <= 64) or not claim_id.replace("-", "").isalnum():
        raise ApiError("invalid_claim_id")
    return claim_id


@app.post("/v1/partner-analyses/claim")
@app.post("/v1/partner-analyses/claim-reward", defaults={"reward_only": True})
def claim_partner_analysis(reward_only=False):
    """Authorize one relationship reading with an available analysis credit."""
    uid = g.firebase["uid"]
    claim_id = _partner_claim_id(_body().get("claim_id"))
    if reward_only:
        consumed, entitlement = store.claim_partner_analysis(uid, claim_id, reward_only=True)
    else:
        _refresh_saved_subscription(uid)
        consumed, entitlement = store.claim_partner_analysis(uid, claim_id)
    return _response({"allowed": True, "credit_consumed": consumed, "entitlement": entitlement})


def _content_id(pipeline_version: str, uid: str, context: dict[str, Any]) -> str:
    canonical = json.dumps(context, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    material = f"{pipeline_version}:{uid}:{canonical}".encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def _call_private_backend(context: dict[str, Any], endpoint: str, response_key: str) -> dict[str, Any]:
    audience = config.INTERNAL_BACKEND_URL
    try:
        bearer = id_token.fetch_id_token(GoogleAuthRequest(), audience)
        response = requests.post(
            audience + endpoint,
            headers={"Authorization": "Bearer " + bearer, "Content-Type": "application/json"},
            json=context,
            timeout=75,
        )
    except Exception as exc:
        raise ApiError("interpretation_unavailable", 502) from exc
    if response.status_code != 200:
        raise ApiError("interpretation_unavailable", 502)
    try:
        value = response.json()
    except ValueError as exc:
        raise ApiError("interpretation_unavailable", 502) from exc
    result = value.get(response_key) if isinstance(value, dict) else None
    if not isinstance(result, dict):
        raise ApiError("interpretation_unavailable", 502)
    return result


def _validated_context() -> dict[str, Any]:
    context = _body()
    if context.get("schema_version") not in {1, 2, 3, 4}:
        raise ApiError("invalid_schema")
    try:
        assert_source_safe(context)
    except ValueError as exc:
        raise ApiError(str(exc)) from exc
    return context


_PARTNER_SECTION_CODES = {
    "CLOSENESS", "EXPECTATIONS", "COMMUNICATION", "DECISIONS",
    "AUTONOMY", "RESPONSIBILITY", "PACE", "DIRECTION",
}
_PARTNER_TEXT_FIELDS = ("narrative", "opportunity", "attention", "practice")


def _partner_context(body: dict[str, Any]) -> dict[str, Any]:
    if set(body) != {"claim_id", "language", "sections"}:
        raise ApiError("invalid_partner_context")
    language = body["language"]
    sections = body["sections"]
    if language not in ("tr", "en") or not isinstance(sections, list) or not 1 <= len(sections) <= 8:
        raise ApiError("invalid_partner_context")
    seen = set()
    for section in sections:
        if not isinstance(section, dict) or set(section) != {"code", *_PARTNER_TEXT_FIELDS}:
            raise ApiError("invalid_partner_context")
        code = section["code"]
        if not isinstance(code, str) or code not in _PARTNER_SECTION_CODES or code in seen:
            raise ApiError("invalid_partner_context")
        if any(not isinstance(section[key], str) or not 1 <= len(section[key].strip()) <= 1400
               for key in _PARTNER_TEXT_FIELDS):
            raise ApiError("invalid_partner_context")
        seen.add(code)
    return {"language": language, "sections": sections}


@app.post("/v1/partner-analyses/interpretation")
def partner_interpretation():
    uid = g.firebase["uid"]
    body = _body()
    claim_id = _partner_claim_id(body.get("claim_id"))
    context = _partner_context(body)
    reservation = store.reserve_partner_ai(uid, claim_id)
    report_id = reservation["report_id"]
    if isinstance(reservation.get("cached"), dict):
        return _response({"report_id": report_id, "reading": reservation["cached"]})
    lease = reservation["lease"]
    try:
        worker_context = {**context, "near_term_months": 3 + int(report_id[:8], 16) % 6}
        reading = _call_private_backend(worker_context, "/v1/internal/partner-interpretation", "reading")
    except Exception:
        store.finish_partner_ai(uid, report_id, lease, None)
        raise
    if not store.finish_partner_ai(uid, report_id, lease, reading):
        raise ApiError("partner_ai_reservation_expired", 409)
    return _response({"report_id": report_id, "reading": reading})


@app.post("/v1/interpretation")
@app.post("/v1/interpretation/reward", defaults={"reward_only": True})
def interpretation(reward_only=False):
    uid = g.firebase["uid"]
    context = _validated_context()
    context.pop("near_term_months", None)
    report_id = _content_id(config.REPORT_PIPELINE_VERSION, uid, context)
    if reward_only:
        reservation = store.reserve_report(uid, report_id, context, reward_only=True)
    else:
        _refresh_saved_subscription(uid)
        reservation = store.reserve_report(uid, report_id, context)
    if isinstance(reservation.get("cached"), dict):
        return _response({"report_id": report_id, "reading": reservation["cached"], "cached": True})
    try:
        # Derive a stable, pseudo-random horizon from the report's content hash.
        worker_context = {**context, "near_term_months": 3 + int(report_id[:8], 16) % 6}
        reading = _call_private_backend(worker_context, "/v1/internal/interpretation", "reading")
        store.complete_report(uid, report_id, reading, context)
    except Exception:
        store.fail_report(uid, report_id)
        raise
    return _response({"report_id": report_id, "reading": reading, "cached": False})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), debug=False)
