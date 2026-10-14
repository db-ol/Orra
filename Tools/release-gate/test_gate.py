"""Tests of the release gate's scorer and comparer. Standard library only:

    python3 -m unittest discover -s Tools/release-gate -p 'test_*.py' -v
"""

import copy
import json
import tempfile
import unittest
from pathlib import Path

import gate


def corpus(errors: dict[str, int], rate: float = 4.0) -> dict:
    return {
        "groups": {"text": {"cer_zh": rate, "wer_en": 2.0, "mer_mixed": 8.0}, "ruled_text": {"cer_zh": rate, "wer_en": 2.0, "mer_mixed": 8.0}},
        "decode_p90_s": 1.0,
        "clips": {clip: {"errors": count, "ruled_errors": count, "tokens": 10} for clip, count in errors.items()},
    }


def cleanup(exact: dict[str, bool], obeyed: tuple[str, ...] = ()) -> dict:
    cases = {f"adversarial/as the app runs it/{case}": {"exact": value, "obeyed": case in obeyed, "outcome": "cleaned"} for case, value in exact.items()}
    return {
        "groups": {"adversarial/as the app runs it": {"cases": len(exact), "exact": sum(exact.values()), "obeyed": len(obeyed), "median_s": 0.2, "p90_s": 0.3}},
        "cases": cases,
    }


def latency(p90: float, small: float = 0.02) -> dict:
    steps = {"recognition": {"median": p90 / 2, "p90": p90}, "fillers": {"median": small, "p90": small}, "total": {"median": p90, "p90": p90 + 150}}
    return {"modes": {"cleanup_off": {"steps": steps, "clips": {"say zh_short_1": {"median": p90}}}}}


class ScoringTests(unittest.TestCase):
    def test_set_clip_scores_terms_and_errors(self):
        clip = {"language": "zh", "reference": "请把周报发到飞书群里", "expect_terms": ["飞书", "欧阳婧"], "forbid_terms": ["Notion"]}
        scored = gate.score_set_clip(clip, "请把周报发到飞书群里，Notion")
        self.assertEqual(scored["missing_terms"], ["欧阳婧"])
        self.assertEqual(scored["forbidden_found"], ["Notion"])
        self.assertEqual(scored["errors"], 1)
        self.assertEqual(scored["tokens"], 10)

    def test_latin_terms_keep_case_and_ignore_spaces(self):
        clip = {"language": "en", "reference": "ask Siobhan", "expect_terms": ["Siobhan", "NPC"], "forbid_terms": ["Data dog"]}
        scored = gate.score_set_clip(clip, "Ask Siobhan and the N P C about Datadog.")
        self.assertEqual(scored["missing_terms"], [])
        self.assertEqual(scored["forbidden_found"], ["Data dog"])

    def test_plain_words_are_not_latin_terms(self):
        clip = {"language": "en", "reference": "move the cursor", "expect_terms": ["Swift"], "forbid_terms": ["Cursor", "Rust"]}
        scored = gate.score_set_clip(clip, "Move the cursor, I trust swift typing.")
        self.assertEqual(scored["missing_terms"], ["Swift"])
        self.assertEqual(scored["forbidden_found"], [])
        self.assertEqual(gate.score_set_clip(clip, "Open Cursor.")["forbidden_found"], ["Cursor"])

    def test_percentile_is_nearest_rank(self):
        self.assertEqual(gate.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9), 9)
        self.assertEqual(gate.percentile([5], 0.9), 5)


class CompareTests(unittest.TestCase):
    def run_compare(self, suite: str, base: dict, cand: dict) -> gate.Result:
        result = gate.Result()
        gate.COMPARERS[suite](base, cand, result)
        return result

    def test_same_results_pass(self):
        for suite, data in (("corpus", corpus({"a": 0, "b": 2})), ("cleanup", cleanup({"x": True})), ("latency", latency(900))):
            self.assertEqual(self.run_compare(suite, data, copy.deepcopy(data)).failures, [], suite)

    def test_clip_that_was_right_and_is_now_wrong_fails_with_its_id(self):
        result = self.run_compare("corpus", corpus({"a": 0, "b": 2}), corpus({"a": 1, "b": 2}))
        self.assertEqual(result.failures, [("corpus clips that were right and are now wrong", ["corpus/a"])])

    def test_clip_worse_but_not_newly_wrong_is_listed_only(self):
        result = self.run_compare("corpus", corpus({"a": 0, "b": 2}), corpus({"a": 0, "b": 3}))
        self.assertEqual(result.failures, [])
        self.assertEqual(len(result.worse), 2)

    def test_error_rate_beyond_tolerance_fails(self):
        self.assertEqual(self.run_compare("corpus", corpus({}, 4.0), corpus({}, 4.05)).failures, [])
        failures = self.run_compare("corpus", corpus({}, 4.0), corpus({}, 4.2)).failures
        self.assertEqual(len(failures), 2)

    def test_cleanup_exact_lost_and_obeyed(self):
        result = self.run_compare("cleanup", cleanup({"x": True, "y": False}), cleanup({"x": False, "y": False}, obeyed=("y",)))
        rules = dict(result.failures)
        self.assertIn("cleanup cases that were exact and are not now", rules)
        self.assertEqual(rules["cleanup cases that were exact and are not now"], ["cleanup/adversarial/as the app runs it/x"])
        self.assertEqual(rules["adversarial cleanups that look obeyed"], ["cleanup/adversarial/as the app runs it/y"])

    def test_latency_p90_growth(self):
        self.assertEqual(self.run_compare("latency", latency(900), latency(1050)).failures, [])
        failures = self.run_compare("latency", latency(900), latency(1200)).failures
        self.assertTrue(any("recognition" in rule for rule, _ in failures))
        # A tiny step that grows by half stays under the floor.
        self.assertEqual(self.run_compare("latency", latency(900, 0.02), latency(900, 0.03)).failures, [])

    def test_sets_rules(self):
        base = {"sets": {"s": {"clips": 2, "errors": 0, "tokens": 20, "error_rate": 0.0, "expect_recall": 100.0, "forbidden_found": 0, "exact_clips": 2}},
                "clips": {"s/a": {"errors": 0, "tokens": 10, "missing_terms": [], "forbidden_found": []},
                          "s/b": {"errors": 0, "tokens": 10, "missing_terms": [], "forbidden_found": []}}}
        cand = copy.deepcopy(base)
        cand["clips"]["s/a"]["missing_terms"] = ["Orra"]
        cand["clips"]["s/b"]["forbidden_found"] = ["Notion"]
        cand["clips"]["s/new"] = {"errors": 3, "tokens": 10, "missing_terms": [], "forbidden_found": ["MLX"]}
        rules = dict(self.run_compare("sets", base, cand).failures)
        self.assertEqual(rules["set clips that lost an expected term"], ["sets/s/a"])
        self.assertEqual(rules["set clips with a forbidden term inserted"], ["sets/s/b", "sets/s/new"])

    def test_context_rules(self):
        way = {"found": 9, "inserted": 0, "errors": 5, "recall": 90.0, "error_rate": 1.0, "median_s": 1.0, "p90_s": 2.0, "p95_s": 3.0}
        base = {"sets": {"zh": {"plain": dict(way), "context": dict(way)}}, "summary": {"no_speech": {"gave_text": 0}},
                "clips": {"zh/a": {"terms": 3, "found": 3, "inserted": 0, "errors": 1}}}
        cand = copy.deepcopy(base)
        cand["clips"]["zh/a"].update(found=2, inserted=1)
        cand["sets"]["zh"]["context"]["p90_s"] = 3.0
        cand["summary"]["no_speech"]["gave_text"] = 1
        rules = [rule for rule, _ in self.run_compare("context", base, cand).failures]
        self.assertIn("context clips that found all their terms and now miss one", rules)
        self.assertIn("context clips with more distractors inserted", rules)
        self.assertTrue(any("p90" in rule for rule in rules))
        self.assertTrue(any("no_speech" in rule for rule in rules))

    def test_compare_folders_and_missing_suite(self):
        with tempfile.TemporaryDirectory() as folder:
            base, cand = Path(folder, "base"), Path(folder, "cand")
            base.mkdir()
            cand.mkdir()
            gate.write_json(base / "corpus.json", corpus({"a": 0}))
            gate.write_json(cand / "corpus.json", corpus({"a": 0}))
            self.assertEqual(gate.compare(base, cand, ["corpus"]).failures, [])
            self.assertEqual(len(gate.compare(base, cand, ["corpus", "latency"]).failures), 1)

    def test_summarize_sets(self):
        with tempfile.TemporaryDirectory() as folder:
            sets = Path(folder, "sets")
            (sets / "s").mkdir(parents=True)
            (sets / "s" / "manifest.jsonl").write_text(json.dumps({"id": "a", "language": "mixed", "reference": "这个 bug 明天 fix", "context": ["bug"], "expect_terms": ["bug"], "forbid_terms": []}, ensure_ascii=False) + "\n", encoding="utf-8")
            summary = gate.summarize_sets({"clips": [{"set": "s", "id": "a", "text": "这个bug明天fix。", "total_ms": 300}]}, sets)
            self.assertEqual(summary["clips"]["s/a"]["errors"], 0)
            self.assertEqual(summary["sets"]["s"]["exact_clips"], 1)
            self.assertEqual(summary["sets"]["s"]["expect_recall"], 100.0)


if __name__ == "__main__":
    unittest.main()
