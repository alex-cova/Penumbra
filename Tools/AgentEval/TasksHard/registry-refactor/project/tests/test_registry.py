import unittest

import app
import cli
import extras
import plugins


class RegistryTests(unittest.TestCase):
    def test_registries_are_independent(self):
        a, b = plugins.Registry(), plugins.Registry()
        app.build(a)
        self.assertEqual(a.names(), ["strip", "upper"])
        self.assertEqual(b.names(), [])

    def test_run(self):
        registry = plugins.Registry()
        app.build(registry)
        self.assertEqual(app.run(registry, "upper", "ab"), "AB")
        self.assertEqual(app.run(registry, "strip", "  x "), "x")

    def test_extras_and_cli(self):
        registry = plugins.Registry()
        extras.install(registry)
        self.assertEqual(cli.available(registry), "title")

    def test_unknown_name(self):
        with self.assertRaises(KeyError):
            plugins.Registry().get("nope")
