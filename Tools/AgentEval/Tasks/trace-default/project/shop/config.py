"""Effective settings: defaults, with environment overrides."""

import os

from shop.defaults import MAX_RETRIES, TIMEOUT_SECONDS


def _env_int(name, fallback):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return fallback


RETRIES = _env_int("SHOP_RETRIES", MAX_RETRIES)
TIMEOUT = _env_int("SHOP_TIMEOUT", TIMEOUT_SECONDS)
