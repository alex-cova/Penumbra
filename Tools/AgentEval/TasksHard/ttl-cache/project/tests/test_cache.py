import unittest

from cache import TTLCache
from clock import FakeClock


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.cache = TTLCache(2, 10, self.clock)

    def test_hit_and_miss(self):
        self.cache.set("a", 1)
        self.assertEqual(self.cache.get("a"), 1)
        self.assertIsNone(self.cache.get("b"))

    def test_entry_is_gone_exactly_at_its_ttl(self):
        self.cache.set("a", 1)
        self.clock.advance(9.9)
        self.assertEqual(self.cache.get("a"), 1)
        self.clock.advance(0.1)
        self.assertIsNone(self.cache.get("a"))

    def test_reading_an_entry_protects_it_from_eviction(self):
        self.cache.set("a", 1)
        self.cache.set("b", 2)
        self.cache.get("a")
        self.cache.set("c", 3)
        self.assertIsNone(self.cache.get("b"))
        self.assertEqual(self.cache.get("a"), 1)
        self.assertEqual(self.cache.get("c"), 3)

    def test_writing_an_existing_key_restarts_its_ttl(self):
        self.cache.set("a", 1)
        self.clock.advance(6)
        self.cache.set("a", 2)
        self.clock.advance(6)
        self.assertEqual(self.cache.get("a"), 2)

    def test_rewriting_a_key_does_not_evict_another(self):
        self.cache.set("a", 1)
        self.cache.set("b", 2)
        self.cache.set("a", 3)
        self.assertEqual(self.cache.get("b"), 2)
        self.assertEqual(self.cache.get("a"), 3)
