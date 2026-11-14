"""Small, non-generative feedback contract shared by routes and storage."""
from __future__ import annotations

MAX_SUGGESTION = 500


def report_id(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("invalid_report_id")
    result = value.strip().lower()
    if len(result) != 64 or any(c not in "0123456789abcdef" for c in result):
        raise ValueError("invalid_report_id")
    return result


def normalize(body: dict) -> dict:
    identifier = report_id(body.get("report_id"))
    rating = body.get("rating")
    if rating is not None and (not isinstance(rating, str) or rating not in {"like", "dislike"}):
        raise ValueError("invalid_feedback_rating")
    suggestion = body.get("suggestion", "")
    if not isinstance(suggestion, str):
        raise ValueError("invalid_feedback_suggestion")
    suggestion = suggestion.strip()
    if len(suggestion) > MAX_SUGGESTION or any(ord(c) < 32 and c not in "\n\t" for c in suggestion):
        raise ValueError("invalid_feedback_suggestion")
    if rating is None and not suggestion:
        raise ValueError("empty_feedback")
    language = body.get("language", "tr")
    if language not in ("tr", "en"):
        raise ValueError("invalid_feedback_language")
    return {"report_id": identifier, "rating": rating, "suggestion": suggestion, "language": language}
