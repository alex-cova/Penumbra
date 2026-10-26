"""Thin client that retries failed requests."""

from shop import config


class Client:
    def __init__(self, retries=None):
        self.retries = config.RETRIES if retries is None else retries

    def fetch(self, url):
        last_error = None
        for _ in range(self.retries + 1):
            try:
                return self._get(url)
            except OSError as error:
                last_error = error
        raise last_error
