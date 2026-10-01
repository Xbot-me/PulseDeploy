"""Unit tests for the pure helpers (standard library only):  python3 -m unittest discover loadtest/tests"""
import copy
import json
import random
import statistics
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import humanlib as hl  # noqa: E402

GOOD = {
    "name": "t", "hosts": ["api"],
    "journeys": [{"name": "j", "weight": 1, "steps": [{"name": "s", "path": "/x"}]}],
}


class ThinkTime(unittest.TestCase):
    def test_median_is_respected_and_tail_is_long(self):
        rng = random.Random(1)
        values = [hl.think_time(rng, {"median": 8, "sigma": 0.8, "min": 0.1, "max": 1000}) for _ in range(6000)]
        self.assertAlmostEqual(statistics.median(values), 8, delta=0.8)
        self.assertGreater(sorted(values)[int(len(values) * 0.95)], 8 * 2)  # a few long pauses, like people
        self.assertLess(sorted(values)[len(values) // 10], 8)  # and many short ones

    def test_clamped_to_min_and_max(self):
        rng = random.Random(2)
        values = [hl.think_time(rng, {"median": 5, "sigma": 2.0, "min": 1.0, "max": 30}) for _ in range(3000)]
        self.assertGreaterEqual(min(values), 1.0)
        self.assertLessEqual(max(values), 30)

    def test_never_zero_or_negative_even_with_odd_input(self):
        rng = random.Random(3)
        for spec in ({}, {"median": 0}, {"median": 0.0001, "min": 0.2}):
            self.assertGreater(hl.think_time(rng, spec), 0)

    def test_count_is_at_least_one(self):
        rng = random.Random(4)
        self.assertTrue(all(hl.count_from(rng, {"median": 0.2, "sigma": 1.0, "min": 0.0}) >= 1 for _ in range(500)))


class Weighted(unittest.TestCase):
    def test_follows_the_weights(self):
        rng = random.Random(5)
        items = [{"n": "a", "weight": 9}, {"n": "b", "weight": 1}]
        picks = [hl.pick_weighted(rng, items)["n"] for _ in range(4000)]
        self.assertAlmostEqual(picks.count("a") / len(picks), 0.9, delta=0.03)

    def test_zero_weight_is_never_chosen(self):
        rng = random.Random(6)
        items = [{"n": "a", "weight": 0}, {"n": "b", "weight": 2}]
        self.assertTrue(all(hl.pick_weighted(rng, items)["n"] == "b" for _ in range(300)))

    def test_all_zero_is_an_error(self):
        with self.assertRaises(hl.ScenarioError):
            hl.pick_weighted(random.Random(7), [{"weight": 0}])


class Templates(unittest.TestCase):
    def test_substitutes_values(self):
        self.assertEqual(hl.render("/o/{id}/x", {"id": 7}), "/o/7/x")

    def test_missing_value_raises(self):
        with self.assertRaises(hl.MissingVar) as ctx:
            hl.render("/o/{id}", {})
        self.assertEqual(ctx.exception.name, "id")

    def test_optional_is_empty_when_unset(self):
        self.assertEqual(hl.render("{cart?}", {}), "")
        self.assertEqual(hl.render("{cart?}", {"cart": "abc"}), "abc")

    def test_any_picks_from_a_shared_list(self):
        self.assertIn(hl.render("{any:ids}", {}, {"ids": [3, 4]}, random.Random(1)), ("3", "4"))

    def test_any_with_empty_list(self):
        with self.assertRaises(hl.MissingVar):
            hl.render("{any:ids}", {}, {"ids": []})
        self.assertEqual(hl.render("{any:ids?}", {}, {}), "")

    def test_render_obj_walks_nested_structures(self):
        out = hl.render_obj({"a": ["{x}", {"b": "{x}-{y}"}], "n": 5}, {"x": 1, "y": 2})
        self.assertEqual(out, {"a": ["1", {"b": "1-2"}], "n": 5})

    def test_braces_that_are_not_tokens_survive(self):
        self.assertEqual(hl.render("a{ b }c", {}), "a{ b }c")


class Extract(unittest.TestCase):
    DATA = {"data": {"token": "t", "items": [{"id": 1, "n": {"v": "x"}}, {"id": 2}, {"id": None}]}}

    def test_paths(self):
        self.assertEqual(hl.extract(self.DATA, "data.token"), "t")
        self.assertEqual(hl.extract(self.DATA, "data.items[0].n.v"), "x")
        self.assertEqual(hl.extract(self.DATA, "data.items[-1].id"), None)

    def test_fan_out_skips_nulls(self):
        self.assertEqual(hl.extract(self.DATA, "data.items[*].id"), [1, 2])

    def test_missing_is_none_not_an_error(self):
        for path in ("nope", "data.nope.x", "data.items[9].id", "data.token[0]"):
            self.assertIsNone(hl.extract(self.DATA, path))
        self.assertEqual(hl.extract({"data": "x"}, "data[*].id"), [])


class Assets(unittest.TestCase):
    HTML = ('<link rel="stylesheet" href="/_next/static/css/a.css?v=1"><script src="/_next/static/a.js"></script>'
            '<script src="//cdn.example.com/x.js"></script><script src="https://evil.example/y.js"></script>'
            '<a href="/orders">x</a><script src="/_next/static/a.js"></script>')

    def test_same_origin_scripts_and_styles_only_deduplicated(self):
        self.assertEqual(hl.asset_paths(self.HTML), ["/_next/static/css/a.css?v=1", "/_next/static/a.js"])

    def test_limit_and_empty(self):
        many = "".join(f'<script src="/s{i}.js"></script>' for i in range(30))
        self.assertEqual(len(hl.asset_paths(many, limit=5)), 5)
        self.assertEqual(hl.asset_paths(""), [])
        self.assertEqual(hl.asset_paths(None), [])


class Validation(unittest.TestCase):
    def problems(self, change):
        scn = copy.deepcopy(GOOD)
        change(scn)
        return hl.validate_scenario(scn)

    def test_good_scenario(self):
        self.assertEqual(hl.validate_scenario(GOOD), [])

    def test_each_kind_of_mistake_is_reported(self):
        cases = {
            "name": lambda s: s.pop("name"),
            "hosts": lambda s: s.update(hosts=[]),
            "journeys": lambda s: s.update(journeys=[]),
            "path must start": lambda s: s["journeys"][0]["steps"][0].update(path="x"),
            "unknown method": lambda s: s["journeys"][0]["steps"][0].update(method="FETCH"),
            "is not in \"hosts\"": lambda s: s["journeys"][0]["steps"][0].update(host="other"),
            "expect must be": lambda s: s["journeys"][0]["steps"][0].update(expect=["200"]),
            "continue_p": lambda s: s["journeys"][0]["steps"][0].update(continue_p=2),
            "must be a number": lambda s: s["journeys"][0]["steps"][0].update(think={"median": "slow"}),
            "extract.v": lambda s: s["journeys"][0]["steps"][0].update(extract={"v": 5}),
            "weight": lambda s: s["journeys"][0].update(weight="heavy"),
        }
        for expected, change in cases.items():
            with self.subTest(expected):
                self.assertTrue(any(expected in p for p in self.problems(change)), self.problems(change))

    def test_not_an_object(self):
        self.assertTrue(hl.validate_scenario([]))

    def test_hosts_used(self):
        scn = copy.deepcopy(GOOD)
        scn["hosts"] = ["api", "admin"]
        scn["setup"] = [{"name": "l", "path": "/l", "host": "admin"}]
        self.assertEqual(hl.hosts_used(scn), ["admin", "api"])


class ShippedScenarios(unittest.TestCase):
    def test_every_shipped_scenario_is_valid(self):
        files = sorted((HERE.parent / "scenarios").glob("*.json"))
        self.assertGreaterEqual(len(files), 2)
        for path in files:
            with self.subTest(path.name):
                hl.load_scenario(path)

    def test_reading_a_broken_file(self):
        bad = HERE / "_broken.json"
        bad.write_text("{not json", encoding="utf-8")
        try:
            with self.assertRaises(hl.ScenarioError):
                hl.load_scenario(bad)
        finally:
            bad.unlink()

    def test_shipped_scenarios_never_write_without_the_flag(self):
        # a step that changes data must say so, or --writes could not protect anyone
        for path in (HERE.parent / "scenarios").glob("*.json"):
            scn = json.loads(path.read_text(encoding="utf-8"))
            for journey in scn["journeys"]:
                for step in journey["steps"]:
                    if str(step.get("method", "GET")).upper() != "GET" or "cart" in step["path"]:
                        self.assertTrue(step.get("writes"), f"{path.name}: {step['name']} changes data but is not marked writes")


if __name__ == "__main__":
    unittest.main()
