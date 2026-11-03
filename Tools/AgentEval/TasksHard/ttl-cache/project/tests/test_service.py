import unittest

from cache import TTLCache
from clock import FakeClock
from service import UserService


class ServiceTests(unittest.TestCase):
    def test_second_read_comes_from_the_cache(self):
        store = {1: {"name": "ann"}}
        service = UserService(store, TTLCache(4, 10, FakeClock()))
        first = service.get(1)
        store[1] = {"name": "changed behind the cache"}
        self.assertEqual(service.get(1), first)

    def test_a_rename_is_visible_on_the_next_read(self):
        service = UserService({1: {"name": "ann"}}, TTLCache(4, 10, FakeClock()))
        service.get(1)
        service.rename(1, "anna")
        self.assertEqual(service.get(1)["name"], "anna")
