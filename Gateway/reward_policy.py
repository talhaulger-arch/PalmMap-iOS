"""Integer-only reward accounting. Ad revenue is estimated, never a cash claim."""
from __future__ import annotations


def reward_price(ai_cost_micros: int, multiplier: int) -> int:
    if type(ai_cost_micros) is not int or not 1 <= ai_cost_micros <= 1_000_000:
        raise ValueError("invalid_reward_ai_cost")
    if type(multiplier) is not int or multiplier not in (3, 5):
        raise ValueError("invalid_reward_multiplier")
    return ai_cost_micros * multiplier


def allocate(balance: int, added: int, price: int, credits: int, limit: int = 100) -> tuple[int, int]:
    if any(type(x) is not int or x < 0 for x in (balance, added, credits, limit)) or price <= 0:
        raise ValueError("invalid_reward_balance")
    total = balance + added
    granted = min(total // price, max(0, limit - credits))
    return total - granted * price, credits + granted


def validate_revenue(body: dict, maximum: int) -> tuple[int, int]:
    value = body.get("value_micros")
    precision = body.get("precision")
    if type(value) is not int or value < 0 or value > maximum:
        raise ValueError("invalid_ad_value")
    if body.get("currency") != "USD":
        raise ValueError("unsupported_ad_currency")
    # UNKNOWN and manual publisher CPMs are not eligible to create rights.
    if type(precision) is not int or precision not in (1, 3):
        raise ValueError("ad_revenue_not_available")
    return value, precision
