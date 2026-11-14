"""Immutable production configuration for the PalmMap public API gateway."""

from __future__ import annotations

import os
from urllib.parse import urlparse


PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "seraphic-camp-507506-m2").strip()
PACKAGE_NAME = os.environ.get("PALMMAP_ANDROID_PACKAGE", "com.palmmap.app").strip()
INAPP_PRODUCT_ID = "elharitasi_deep_report"
PARTNER_ANALYSIS_PRODUCT_ID = "elharitasi_partner_analysis"
INAPP_PRODUCT_IDS = frozenset({INAPP_PRODUCT_ID, PARTNER_ANALYSIS_PRODUCT_ID})
SUBSCRIPTION_PRODUCT_ID = "elharitasi_plus"
ALLOWED_BASE_PLANS = frozenset({"monthly"})
INTERNAL_BACKEND_URL = os.environ.get("PALMMAP_INTERNAL_BACKEND_URL", "").strip().rstrip("/")
MAX_BODY_BYTES = 256 * 1024
MAX_REPORT_CREDITS = 100
MAX_PARTNER_CREDITS = 100
PLUS_MONTHLY_CREDITS = 30
REPORT_PIPELINE_VERSION = "palmmap-interpretation-v11-personal-outlook"
RELATIONSHIP_AI_POLICY = "palmmap-relationship-v2"
SUPPORT_EMAIL = os.environ.get("PALMMAP_SUPPORT_EMAIL", "").strip()
FIREBASE_WEB_API_KEY = os.environ.get("PALMMAP_FIREBASE_WEB_API_KEY", "").strip()
REWARDED_ADS_ENABLED = os.environ.get("PALMMAP_REWARDED_ADS_ENABLED", "false").lower() == "true"
REWARDED_AD_UNIT = os.environ.get("PALMMAP_REWARDED_AD_UNIT", "").strip()
REWARD_REQUIRE_APP_CHECK = os.environ.get("PALMMAP_REWARD_REQUIRE_APP_CHECK", "true").lower() == "true"
REWARD_MULTIPLIER = int(os.environ.get("PALMMAP_REWARD_MULTIPLIER", "5"))
REWARD_AI_COST_MICROS = int(os.environ.get("PALMMAP_REWARD_AI_COST_MICROS", "7000"))
REWARD_MAX_VALUE_MICROS = int(os.environ.get("PALMMAP_REWARD_MAX_VALUE_MICROS", "20000"))
REWARD_DAILY_LIMIT = int(os.environ.get("PALMMAP_REWARD_DAILY_LIMIT", "30"))


APPLE_STORE_ENABLED = os.environ.get("PALMMAP_APPLE_STORE_ENABLED", "false").lower() == "true"
APPLE_BUNDLE_ID = os.environ.get("PALMMAP_APPLE_BUNDLE_ID", "com.palmmap.app").strip()
APPLE_APP_ID = int(os.environ.get("PALMMAP_APPLE_APP_ID", "0"))
APPLE_ROOT_CERTS_DIR = os.environ.get("PALMMAP_APPLE_ROOT_CERTS_DIR", "/var/palmmap/apple-roots").strip()
APPLE_SANDBOX_UIDS = frozenset(uid.strip() for uid in os.environ.get("PALMMAP_APPLE_SANDBOX_UIDS", "").split(",") if uid.strip())
IOS_REWARDED_AD_UNIT = os.environ.get("PALMMAP_IOS_REWARDED_AD_UNIT", "").strip()
IOS_FIREBASE_APP_ID = os.environ.get("PALMMAP_IOS_FIREBASE_APP_ID", "").strip()


def validate() -> None:
    from reward_policy import reward_price
    reward_price(REWARD_AI_COST_MICROS, REWARD_MULTIPLIER)
    if not 1 <= REWARD_MAX_VALUE_MICROS <= 100_000 or not 1 <= REWARD_DAILY_LIMIT <= 100:
        raise RuntimeError("Invalid reward exposure limits")
    if REWARDED_ADS_ENABLED and (not REWARDED_AD_UNIT.startswith("ca-app-pub-") or "/" not in REWARDED_AD_UNIT or "3940256099942544" in REWARDED_AD_UNIT):
        raise RuntimeError("A real PALMMAP_REWARDED_AD_UNIT is required; test ads never grant real rights")
    if APPLE_STORE_ENABLED and (not APPLE_BUNDLE_ID or APPLE_APP_ID <= 0 or not APPLE_ROOT_CERTS_DIR):
        raise RuntimeError("App Store verification requires a bundle ID, numeric app ID and Apple root certificates")
    if IOS_REWARDED_AD_UNIT and (not IOS_FIREBASE_APP_ID or not IOS_REWARDED_AD_UNIT.startswith("ca-app-pub-")
            or "/" not in IOS_REWARDED_AD_UNIT or "3940256099942544" in IOS_REWARDED_AD_UNIT):
        raise RuntimeError("iOS rewards require a live iOS rewarded ad unit and the iOS Firebase app ID")
    if PROJECT_ID != "seraphic-camp-507506-m2":
        raise RuntimeError("Unexpected GOOGLE_CLOUD_PROJECT")
    if PACKAGE_NAME != "com.palmmap.app":
        raise RuntimeError("Unexpected PALMMAP_ANDROID_PACKAGE")
    if not INTERNAL_BACKEND_URL:
        raise RuntimeError("PALMMAP_INTERNAL_BACKEND_URL is required")
    if not FIREBASE_WEB_API_KEY.startswith("AIza") or len(FIREBASE_WEB_API_KEY) < 30:
        raise RuntimeError("PALMMAP_FIREBASE_WEB_API_KEY is required")
    parsed = urlparse(INTERNAL_BACKEND_URL)
    if parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith(".run.app"):
        raise RuntimeError("PALMMAP_INTERNAL_BACKEND_URL must be an https://*.run.app URL")
