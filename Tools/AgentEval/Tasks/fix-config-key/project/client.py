"""A client configured from settings.json."""

import json
import os

DEFAULT_TIMEOUT = 5


def load_settings(path=None):
    path = path or os.path.join(os.path.dirname(__file__), "settings.json")
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


class Client:
    def __init__(self, settings=None):
        settings = load_settings() if settings is None else settings
        self.url = "http://%s:%d" % (settings["host"], settings["port"])
        self.timeout = settings.get("timeout", DEFAULT_TIMEOUT)
        self.retries = settings.get("retries", 0)
