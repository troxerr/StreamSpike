"""Offline tests: no network, no API key. Run: python3 -m unittest test_reply_drafter.py"""
import json
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from types import SimpleNamespace

import reply_drafter as rd

EXAMPLE = Path(__file__).with_name("posts.example.txt")


class FakeClient:
    """Stands in for anthropic.Anthropic(); records each request."""

    def __init__(self, results):
        self.results = list(results)
        self.calls = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    def _create(self, **kwargs):
        self.calls.append(kwargs)
        result = self.results.pop(0)
        if result == "refusal":
            return SimpleNamespace(stop_reason="refusal", content=[])
        return SimpleNamespace(stop_reason="end_turn",
                               content=[SimpleNamespace(type="text", text=json.dumps(result))])


def result(relevant=True, score=7, reply="Try chat spikes: count messages per 5 s and flag the jumps."):
    return {"relevant": relevant, "lead_score": score, "reason": "clipping pain",
            "mentions_product": False, "reply": reply if relevant else ""}


class ParseTests(unittest.TestCase):
    def test_example_file(self):
        posts = rd.parse_posts_file(EXAMPLE.read_text())
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[0].author, "@example_streamer")
        self.assertEqual(posts[0].post_id, "1800000000000000001")
        self.assertIn("scrubbing", posts[0].text)

    def test_reply_link_is_composer_intent(self):
        post = rd.Post("https://x.com/a/status/42", "hi")
        link = rd.Draft(post, True, 5, "", False, "Hello & thanks").reply_link()
        parsed = urllib.parse.urlparse(link)
        self.assertEqual(parsed.netloc + parsed.path, "x.com/intent/post")
        self.assertEqual(urllib.parse.parse_qs(parsed.query), {"in_reply_to": ["42"], "text": ["Hello & thanks"]})


class RunTests(unittest.TestCase):
    def run_tool(self, client, *extra):
        out = Path(tempfile.mkdtemp())
        code = rd.main(["--posts", str(EXAMPLE), "--out", str(out), *extra], client=client)
        return code, out

    def test_writes_drafts_and_never_posts(self):
        client = FakeClient([result(score=9), result(relevant=False)])
        code, out = self.run_tool(client)
        self.assertEqual(code, 0)
        md = next(out.glob("*.md")).read_text()
        self.assertIn("Nothing here has been posted", md)
        self.assertIn("lead 9/10", md)
        self.assertIn("## Skipped", md)
        self.assertIn("x.com/intent/post", md)
        # Only Messages API calls happen; the client is never asked to do anything else.
        self.assertEqual(len(client.calls), 2)
        self.assertTrue(all(c["fallbacks"] == "default" for c in client.calls))

    def test_dedup_across_runs(self):
        out = Path(tempfile.mkdtemp())
        rd.main(["--posts", str(EXAMPLE), "--out", str(out)], client=FakeClient([result(), result()]))
        second = FakeClient([])
        rd.main(["--posts", str(EXAMPLE), "--out", str(out)], client=second)
        self.assertEqual(second.calls, [])

    def test_refusal_is_skipped(self):
        code, out = self.run_tool(FakeClient(["refusal", result()]))
        md = next(out.glob("*.md")).read_text()
        self.assertIn("model declined", md)

    def test_long_reply_is_trimmed(self):
        code, out = self.run_tool(FakeClient([result(reply="word " * 100), result(relevant=False)]))
        md = next(out.glob("*.md")).read_text()
        reply_line = md.split("**Draft reply** (")[1].split(" chars")[0]
        self.assertLessEqual(int(reply_line), rd.MAX_REPLY_CHARS)

    def test_dry_run_calls_nothing(self):
        client = FakeClient([])
        code, _ = self.run_tool(client, "--dry-run")
        self.assertEqual((code, client.calls), (0, []))


class SafetyTests(unittest.TestCase):
    def test_no_posting_or_scraping_code(self):
        source = Path(rd.__file__).read_text()
        for banned in ("playwright", "selenium", "browse ", "/2/tweets\"", "statuses/update",
                       "method=\"POST\"", "/likes", "/following", "dm_conversations"):
            self.assertNotIn(banned, source)
        self.assertIn("search/recent", source)


if __name__ == "__main__":
    unittest.main()
